-- =====================================================================
--  AiliNaX カジノ  サーバー側（Supabase の SQL Editor に貼って Run）
--  ・AiliNaX は架空通貨です。現金・物・他の通貨との交換はできません。
--  ・残高と勝ち負けの抽選はすべてこの関数の中（サーバー側）で行います。
--    画面からは残高を書きかえられません。
--  ・何度 Run しても大丈夫です（作り直しになります。残高は消えません）。
-- =====================================================================

-- ---------------------------------------------------------------------
-- テーブル
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null,
  balance    bigint not null default 0 check (balance >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.tx_log (
  id            bigserial primary key,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  game          text not null,
  bet           bigint not null default 0,
  payout        bigint not null default 0,
  balance_after bigint not null,
  detail        jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists tx_log_user_idx on public.tx_log(user_id, id desc);

create table if not exists public.hilo_games (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  bet     bigint not null,
  card    int not null,
  mult    numeric not null default 1,
  steps   int not null default 0,
  cards   int[] not null
);

create table if not exists public.bj_games (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  bet     bigint not null,
  shoe    int[] not null,
  pos     int not null,
  player  int[] not null,
  dealer  int[] not null,
  doubled boolean not null default false
);

create table if not exists public.races (
  id      bigint primary key,
  horses  jsonb not null,
  result  int[] not null,
  seed    int not null,
  settled boolean not null default false
);

create table if not exists public.race_bets (
  id         bigserial primary key,
  race_id    bigint not null references public.races(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  horse      int not null check (horse between 1 and 8),
  kind       text not null check (kind in ('win','place')),
  amount     bigint not null check (amount > 0),
  payout     bigint,
  created_at timestamptz not null default now()
);
create index if not exists race_bets_race_idx on public.race_bets(race_id);
create index if not exists race_bets_user_idx on public.race_bets(user_id, race_id desc);

-- 画面から直接テーブルを読み書きさせない（全部 下の関数を通す）
alter table public.profiles   enable row level security;
alter table public.tx_log     enable row level security;
alter table public.hilo_games enable row level security;
alter table public.bj_games   enable row level security;
alter table public.races      enable row level security;
alter table public.race_bets  enable row level security;
revoke all on public.profiles, public.tx_log, public.hilo_games, public.bj_games,
              public.races, public.race_bets from anon, authenticated;

-- ---------------------------------------------------------------------
-- 内部用の小さな関数
-- ---------------------------------------------------------------------
create or replace function public._me() returns uuid
language plpgsql stable set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'ログインしてください'; end if;
  return u;
end $$;

create or replace function public._rint(n int) returns int
language sql volatile as $$ select floor(random() * n)::int $$;

-- 賭け金を引く
create or replace function public._take(u uuid, amt bigint) returns bigint
language plpgsql set search_path = public as $$
declare b bigint;
begin
  if amt is null or amt < 1 then raise exception '賭け金は1以上にしてください'; end if;
  update profiles set balance = balance - amt where id = u and balance >= amt returning balance into b;
  if not found then raise exception 'AiliNaXが足りません'; end if;
  return b;
end $$;

-- 払い戻す
create or replace function public._give(u uuid, amt bigint) returns bigint
language plpgsql set search_path = public as $$
declare b bigint;
begin
  update profiles set balance = balance + greatest(amt, 0) where id = u returning balance into b;
  return b;
end $$;

create or replace function public._bal(u uuid) returns bigint
language sql stable set search_path = public as $$ select balance from profiles where id = u $$;

create or replace function public._log(u uuid, g text, bet bigint, pay bigint, d jsonb) returns void
language sql set search_path = public as $$
  insert into tx_log(user_id, game, bet, payout, balance_after, detail)
  values (u, g, bet, pay, (select balance from profiles where id = u), d)
$$;

-- カード 0〜51 → {r:1..13, s:0..3}
create or replace function public._card(c int) returns jsonb
language sql immutable as $$ select jsonb_build_object('r', c % 13 + 1, 's', c / 13) $$;

create or replace function public._cards(cs int[]) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(public._card(c) order by o), '[]'::jsonb) from unnest(cs) with ordinality t(c, o)
$$;

-- ---------------------------------------------------------------------
-- プロフィール
-- ---------------------------------------------------------------------
-- ログインしたら毎回呼ぶ。初めての人にだけ 1000 AiliNaX を配る（1回きり）
create or replace function public.ensure_profile() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  insert into profiles(id, nickname, balance)
  values (u, 'プレイヤー' || lpad(_rint(10000)::text, 4, '0'), 1000)
  on conflict (id) do nothing;
  if found then perform _log(u, 'start', 0, 1000, '{"note":"はじめての配布"}'); end if;
  return (select jsonb_build_object('nickname', nickname, 'balance', balance) from profiles where id = u);
end $$;

create or replace function public.my_profile() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('nickname', nickname, 'balance', balance) from profiles where id = _me()
$$;

create or replace function public.set_nickname(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name, ''));
begin
  if char_length(n) < 1 or char_length(n) > 12 then raise exception 'ニックネームは1〜12文字です'; end if;
  update profiles set nickname = n where id = _me();
  return my_profile();
end $$;

create or replace function public.leaderboard() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('nickname', nickname, 'balance', balance) order by balance desc, created_at), '[]'::jsonb)
  from (select nickname, balance, created_at from profiles order by balance desc, created_at limit 20) t
$$;

create or replace function public.my_history() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('game', game, 'bet', bet, 'payout', payout,
           'balance', balance_after, 'at', created_at) order by id desc), '[]'::jsonb)
  from (select * from tx_log where user_id = _me() order by id desc limit 30) t
$$;

-- ---------------------------------------------------------------------
-- スロット（還元率 約95%）
--   絵柄 0:7 1:BAR 2:ベル 3:スイカ 4:レモン 5:チェリー
--   3つそろい ×300 ×75 ×25 ×12 ×10 ×8 / 左からチェリー2つ ×3 / 左端チェリー ×1
-- ---------------------------------------------------------------------
create or replace function public._slot_sym() returns int
language plpgsql volatile as $$
declare x int := _rint(21);  -- 重み 1,2,3,4,5,6
begin
  return case when x < 1 then 0 when x < 3 then 1 when x < 6 then 2
              when x < 10 then 3 when x < 15 then 4 else 5 end;
end $$;

create or replace function public.slot_spin(p_bet bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); a int; b int; c int; m int := 0; pay bigint;
begin
  perform _take(u, p_bet);
  a := _slot_sym(); b := _slot_sym(); c := _slot_sym();
  if a = b and b = c then m := (array[300,75,25,12,10,8])[a + 1];
  elsif a = 5 and b = 5 then m := 3;
  elsif a = 5 then m := 1;
  end if;
  pay := p_bet * m;
  perform _give(u, pay);
  perform _log(u, 'slot', p_bet, pay, jsonb_build_object('reels', jsonb_build_array(a, b, c)));
  return jsonb_build_object('reels', jsonb_build_array(a, b, c), 'mult', m, 'payout', pay, 'balance', _bal(u));
end $$;

-- ---------------------------------------------------------------------
-- ルーレット（ヨーロピアン 0〜36）
--   p_bets = [{"t":"n","v":17,"a":10}, {"t":"red","a":5}, {"t":"dz","v":1,"a":5}, ...]
--   t: n(数字 ×36) red black odd even low high(×2) dz col(v=1..3 ×3)
-- ---------------------------------------------------------------------
create or replace function public.roulette_spin(p_bets jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _me(); n int; total bigint := 0; pay bigint := 0; e jsonb;
  t text; v int; a bigint; win boolean; mult int; red boolean;
  reds int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
begin
  if jsonb_typeof(p_bets) <> 'array' or jsonb_array_length(p_bets) = 0 then raise exception '賭けてください'; end if;
  if jsonb_array_length(p_bets) > 60 then raise exception '賭けが多すぎます'; end if;
  for e in select * from jsonb_array_elements(p_bets) loop
    t := e->>'t'; a := (e->>'a')::bigint; v := nullif(e->>'v', '')::int;
    if a is null or a < 1 then raise exception '賭け金は1以上にしてください'; end if;
    if t not in ('n','red','black','odd','even','low','high','dz','col') then raise exception '知らない賭け方です'; end if;
    if t = 'n' and (v is null or v < 0 or v > 36) then raise exception '数字は0〜36です'; end if;
    if t in ('dz','col') and (v is null or v < 1 or v > 3) then raise exception '1〜3をえらんでください'; end if;
    total := total + a;
  end loop;
  perform _take(u, total);
  n := _rint(37);
  red := n = any(reds);
  for e in select * from jsonb_array_elements(p_bets) loop
    t := e->>'t'; a := (e->>'a')::bigint; v := nullif(e->>'v', '')::int;
    win := case t
      when 'n'     then n = v
      when 'red'   then n > 0 and red
      when 'black' then n > 0 and not red
      when 'odd'   then n > 0 and n % 2 = 1
      when 'even'  then n > 0 and n % 2 = 0
      when 'low'   then n between 1 and 18
      when 'high'  then n between 19 and 36
      when 'dz'    then n > 0 and (n - 1) / 12 + 1 = v
      when 'col'   then n > 0 and ((n - 1) % 3) + 1 = v
    end;
    mult := case when t = 'n' then 36 when t in ('dz','col') then 3 else 2 end;
    if win then pay := pay + a * mult; end if;
  end loop;
  perform _give(u, pay);
  perform _log(u, 'roulette', total, pay, jsonb_build_object('number', n));
  return jsonb_build_object('number', n, 'red', red, 'bet', total, 'payout', pay, 'balance', _bal(u));
end $$;

-- ---------------------------------------------------------------------
-- ハイ＆ロー（A が一番小さく K が一番大きい。同じ数字は負け）
--   当たるたびに倍率が 0.95 ÷ 当たる確率 だけ増える。好きなときに受け取れる
-- ---------------------------------------------------------------------
create or replace function public._hilo_json(g hilo_games, extra jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare r int;
begin
  if g.user_id is null then
    return jsonb_build_object('active', false, 'balance', _bal(_me())) || coalesce(extra, '{}'::jsonb);
  end if;
  r := g.card % 13 + 1;
  return jsonb_build_object(
    'active', true, 'bet', g.bet, 'card', _card(g.card), 'cards', _cards(g.cards),
    'mult', round(g.mult, 2), 'steps', g.steps, 'cashout', floor(g.bet * g.mult),
    'up',   case when r < 13 then floor(0.95 / ((13 - r) / 13.0) * 100) / 100 end,
    'down', case when r > 1  then floor(0.95 / ((r - 1) / 13.0) * 100) / 100 end,
    'balance', _bal(g.user_id)) || coalesce(extra, '{}'::jsonb);
end $$;

create or replace function public.hilo_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare g hilo_games;
begin
  select * into g from hilo_games where user_id = _me();
  return _hilo_json(g, null);
end $$;

create or replace function public.hilo_start(p_bet bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g hilo_games; c int := _rint(52);
begin
  if exists (select 1 from hilo_games where user_id = u) then raise exception 'ゲームの途中です'; end if;
  perform _take(u, p_bet);
  insert into hilo_games(user_id, bet, card, cards) values (u, p_bet, c, array[c]) returning * into g;
  return _hilo_json(g, null);
end $$;

create or replace function public.hilo_guess(p_dir text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g hilo_games; c int; r int; nr int; p numeric; ok boolean; pay bigint;
begin
  select * into g from hilo_games where user_id = u for update;
  if not found then raise exception 'ゲームが始まっていません'; end if;
  r := g.card % 13 + 1;
  p := case when p_dir = 'up' then (13 - r) / 13.0 when p_dir = 'down' then (r - 1) / 13.0 end;
  if p is null or p = 0 then raise exception 'その予想はできません'; end if;
  c := _rint(52); nr := c % 13 + 1;
  ok := (p_dir = 'up' and nr > r) or (p_dir = 'down' and nr < r);
  if not ok then
    delete from hilo_games where user_id = u;
    perform _log(u, 'hilo', g.bet, 0, jsonb_build_object('steps', g.steps));
    return jsonb_build_object('active', false, 'result', 'lose', 'next', _card(c),
             'cards', _cards(g.cards || c), 'payout', 0, 'balance', _bal(u));
  end if;
  update hilo_games set card = c, cards = (cards || c)[greatest(1, array_length(cards, 1) - 10):],
         mult = least(mult * floor(0.95 / p * 100) / 100, 100000), steps = steps + 1
   where user_id = u returning * into g;
  return _hilo_json(g, jsonb_build_object('result', 'win', 'next', _card(c)));
end $$;

create or replace function public.hilo_cashout() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g hilo_games; pay bigint;
begin
  select * into g from hilo_games where user_id = u for update;
  if not found then raise exception 'ゲームが始まっていません'; end if;
  if g.steps < 1 then raise exception '1回は当ててから受け取れます'; end if;
  pay := floor(g.bet * g.mult);
  delete from hilo_games where user_id = u;
  perform _give(u, pay);
  perform _log(u, 'hilo', g.bet, pay, jsonb_build_object('steps', g.steps, 'mult', g.mult));
  return jsonb_build_object('active', false, 'result', 'cashout', 'payout', pay, 'balance', _bal(u));
end $$;

-- ---------------------------------------------------------------------
-- ブラックジャック（6デッキ・ディーラーはソフト17で止まる・BJは3:2・ダブルあり）
-- ---------------------------------------------------------------------
create or replace function public._bj_total(cs int[]) returns int
language plpgsql immutable as $$
declare t int := 0; aces int := 0; c int; r int;
begin
  foreach c in array cs loop
    r := c % 13 + 1;
    if r = 1 then aces := aces + 1; t := t + 11;
    elsif r >= 10 then t := t + 10;
    else t := t + r; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end $$;

create or replace function public._bj_json(g bj_games, done boolean, res text, pay bigint) returns jsonb
language plpgsql set search_path = public as $$
begin
  return jsonb_build_object(
    'active', not done, 'bet', g.bet, 'doubled', g.doubled,
    'player', _cards(g.player), 'ptotal', _bj_total(g.player),
    'dealer', case when done then _cards(g.dealer) else jsonb_build_array(_card(g.dealer[1])) end,
    'dtotal', case when done then _bj_total(g.dealer) else _bj_total(array[g.dealer[1]]) end,
    'hidden', not done,
    'canDouble', not done and array_length(g.player, 1) = 2,
    'result', res, 'payout', pay, 'balance', _bal(g.user_id));
end $$;

-- 勝負をつける（ディーラーが引く→精算）
create or replace function public._bj_finish(g bj_games, dealer_plays boolean) returns jsonb
language plpgsql set search_path = public as $$
declare p int := _bj_total(g.player); d int; res text; pay bigint := 0;
begin
  if p > 21 then res := 'bust';
  else
    if dealer_plays then
      while _bj_total(g.dealer) < 17 loop
        g.dealer := g.dealer || g.shoe[g.pos]; g.pos := g.pos + 1;
      end loop;
    end if;
    d := _bj_total(g.dealer);
    if d > 21 or p > d then res := 'win'; pay := g.bet * 2;
    elsif p = d then res := 'push'; pay := g.bet;
    else res := 'lose'; end if;
  end if;
  delete from bj_games where user_id = g.user_id;
  perform _give(g.user_id, pay);
  perform _log(g.user_id, 'blackjack', g.bet, pay, jsonb_build_object('result', res));
  return _bj_json(g, true, res, pay);
end $$;

create or replace function public.bj_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare g bj_games;
begin
  select * into g from bj_games where user_id = _me();
  if not found then return jsonb_build_object('active', false, 'balance', _bal(_me())); end if;
  return _bj_json(g, false, null, null);
end $$;

create or replace function public.bj_start(p_bet bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g bj_games; s int[]; pbj boolean; dbj boolean; pay bigint; res text;
begin
  if exists (select 1 from bj_games where user_id = u) then raise exception 'ゲームの途中です'; end if;
  perform _take(u, p_bet);
  select array_agg(c order by random()) into s from (select generate_series(0, 311) % 52 as c) t;
  insert into bj_games(user_id, bet, shoe, pos, player, dealer)
  values (u, p_bet, s, 5, array[s[1], s[3]], array[s[2], s[4]]) returning * into g;
  pbj := _bj_total(g.player) = 21; dbj := _bj_total(g.dealer) = 21;
  if pbj or dbj then
    if pbj and dbj then res := 'push'; pay := p_bet;
    elsif pbj then res := 'blackjack'; pay := p_bet + floor(p_bet * 1.5);
    else res := 'lose'; pay := 0; end if;
    delete from bj_games where user_id = u;
    perform _give(u, pay);
    perform _log(u, 'blackjack', p_bet, pay, jsonb_build_object('result', res));
    return _bj_json(g, true, res, pay);
  end if;
  return _bj_json(g, false, null, null);
end $$;

create or replace function public.bj_hit() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g bj_games;
begin
  select * into g from bj_games where user_id = u for update;
  if not found then raise exception 'ゲームが始まっていません'; end if;
  update bj_games set player = player || shoe[pos], pos = pos + 1 where user_id = u returning * into g;
  if _bj_total(g.player) >= 21 then return _bj_finish(g, true); end if;
  return _bj_json(g, false, null, null);
end $$;

create or replace function public.bj_stand() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g bj_games;
begin
  select * into g from bj_games where user_id = u for update;
  if not found then raise exception 'ゲームが始まっていません'; end if;
  return _bj_finish(g, true);
end $$;

create or replace function public.bj_double() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g bj_games;
begin
  select * into g from bj_games where user_id = u for update;
  if not found then raise exception 'ゲームが始まっていません'; end if;
  if array_length(g.player, 1) <> 2 then raise exception 'ダブルは最初の2枚のときだけです'; end if;
  perform _take(u, g.bet);
  update bj_games set bet = bet * 2, doubled = true, player = player || shoe[pos], pos = pos + 1
   where user_id = u returning * into g;
  return _bj_finish(g, true);
end $$;

-- ---------------------------------------------------------------------
-- 競馬（みんなで同じレースに参加）
--   3分ごとに1レース： 0〜120秒 投票 → 120〜150秒 レース → 150〜180秒 結果
--   単勝（1着をあてる）・複勝（3着までに入る）。オッズはレース前に決まる固定オッズ
-- ---------------------------------------------------------------------
create or replace function public._race_cur() returns bigint
language sql stable as $$ select floor(extract(epoch from now()) / 180)::bigint $$;

create or replace function public._race_get(rid bigint) returns races
language plpgsql set search_path = public as $$
declare
  r races; names text[]; picked text[]; s numeric[]; tot numeric; pw numeric[]; pp numeric[];
  i int; j int; k int; q numeric; rem int[]; ord int[]; x numeric; acc numeric; hs jsonb := '[]';
begin
  select * into r from races where id = rid;
  if found then return r; end if;

  names := array['サクラノカゼ','ミナミノヒカリ','ゴールドアイリン','シンデンハヤテ','ヒノデスター','アオゾラダッシュ',
    'ムサシノオー','タマガワリバー','カゼノマタサブロウ','イナズマポテト','ハッピーナックス','モチモチダイフク',
    'ヨゾラノツキ','ハヤブサエクスプレス','ノハラノウサギ','キンイロバナナ','ダイヤモンドライン','コガネムシ',
    'シロクマパンチ','ナナイロレインボー','トウキョウドリーム','ヒミツノハナゾノ','ポンポコリン','スイスイラン',
    'カミナリボルト','アメアガリ','ホシフルヨル','マッチャラテ','オオゾラノツバサ','ミラクルナイン',
    'ハルカゼメイト','タビダチノアサ'];
  select array_agg(n order by random()) into picked from (select unnest(names) n) t;
  picked := picked[1:8];

  -- 強さ（大きいほど勝ちやすい）
  s := array[]::numeric[];
  for i in 1..8 loop s := s || round(((0.45 + random()) ^ 2 * 100)::numeric, 1); end loop;
  select sum(v) into tot from unnest(s) v;

  -- 1着になる確率と、3着までに入る確率（すべての並びを数えて正確に出す）
  pw := array[0,0,0,0,0,0,0,0]::numeric[]; pp := pw;
  for i in 1..8 loop
    pw[i] := s[i] / tot;
    for j in 1..8 loop
      continue when j = i;
      for k in 1..8 loop
        continue when k = i or k = j;
        q := (s[i] / tot) * (s[j] / (tot - s[i])) * (s[k] / (tot - s[i] - s[j]));
        pp[i] := pp[i] + q; pp[j] := pp[j] + q; pp[k] := pp[k] + q;
      end loop;
    end loop;
  end loop;
  for i in 1..8 loop
    hs := hs || jsonb_build_object('no', i, 'name', picked[i], 'str', s[i],
      'odds',  round(greatest(1.1, floor(0.8 / pw[i] * 10) / 10), 1),
      'place', round(greatest(1.0, floor(0.85 / pp[i] * 10) / 10), 1));
  end loop;

  -- 着順を強さに応じて決める（結果はレース開始まで画面に出さない）
  rem := array[1,2,3,4,5,6,7,8]; ord := array[]::int[];
  while array_length(rem, 1) > 0 loop
    select sum(s[v]) into tot from unnest(rem) v;
    x := random() * tot; acc := 0;
    foreach i in array rem loop
      acc := acc + s[i];
      if x < acc or i = rem[array_length(rem, 1)] then
        ord := ord || i; rem := array_remove(rem, i); exit;
      end if;
    end loop;
  end loop;

  insert into races(id, horses, result, seed) values (rid, hs, ord, _rint(2000000000))
  on conflict (id) do nothing;
  select * into r from races where id = rid;
  return r;
end $$;

create or replace function public._race_settle(rid bigint) returns void
language plpgsql set search_path = public as $$
declare r races; b race_bets; o numeric; pay bigint;
begin
  if extract(epoch from now()) < rid * 180 + 150 then return; end if;
  select * into r from races where id = rid for update;
  if not found or r.settled then return; end if;
  for b in select * from race_bets where race_id = rid and payout is null for update loop
    pay := 0;
    if b.kind = 'win' and r.result[1] = b.horse then
      o := (r.horses -> (b.horse - 1) ->> 'odds')::numeric; pay := floor(b.amount * o);
    elsif b.kind = 'place' and b.horse = any(r.result[1:3]) then
      o := (r.horses -> (b.horse - 1) ->> 'place')::numeric; pay := floor(b.amount * o);
    end if;
    update race_bets set payout = pay where id = b.id;
    perform _give(b.user_id, pay);
    perform _log(b.user_id, 'race', b.amount, pay,
      jsonb_build_object('race', rid, 'horse', b.horse, 'kind', b.kind));
  end loop;
  update races set settled = true where id = rid;
end $$;

create or replace function public.race_bet(p_race bigint, p_horse int, p_kind text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); cur bigint := _race_cur();
begin
  if p_race <> cur or extract(epoch from now()) >= cur * 180 + 120 then
    raise exception 'このレースの投票はしめきりました';
  end if;
  if p_horse is null or p_horse < 1 or p_horse > 8 then raise exception '馬をえらんでください'; end if;
  if p_kind not in ('win','place') then raise exception '単勝か複勝をえらんでください'; end if;
  perform _race_get(cur);
  perform _take(u, p_amount);
  insert into race_bets(race_id, user_id, horse, kind, amount) values (cur, u, p_horse, p_kind, p_amount);
  return race_state();
end $$;

create or replace function public.race_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _me(); cur bigint := _race_cur(); r races; t numeric; rid bigint; shown boolean;
  pool jsonb; feed jsonb; mine jsonb; hist jsonb; prev jsonb;
begin
  -- 終わったレースの払い戻し（見に来た人がいれば自動で精算）
  for rid in select id from races where not settled and id <= cur order by id limit 20 loop
    perform _race_settle(rid);
  end loop;
  r := _race_get(cur);
  t := extract(epoch from now()) - cur * 180;
  if t >= 150 then perform _race_settle(cur); end if;
  shown := t >= 120;

  select coalesce(jsonb_agg(jsonb_build_object('horse', horse, 'kind', kind, 'total', total, 'count', cnt)), '[]')
    into pool
    from (select horse, kind, sum(amount) total, count(distinct user_id) cnt
            from race_bets where race_id = cur group by horse, kind) z;

  select coalesce(jsonb_agg(jsonb_build_object('nickname', nickname, 'horse', horse, 'kind', kind,
           'amount', amount, 'payout', payout, 'me', user_id = u) order by id desc), '[]')
    into feed
    from (select b.id, b.horse, b.kind, b.amount, b.payout, b.user_id, p.nickname
            from race_bets b join profiles p on p.id = b.user_id
           where b.race_id = cur order by b.id desc limit 30) z;

  select coalesce(jsonb_agg(jsonb_build_object('horse', horse, 'kind', kind, 'amount', amount, 'payout', payout) order by id), '[]')
    into mine from race_bets where race_id = cur and user_id = u;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'top3', jsonb_build_array(result[1], result[2], result[3]),
           'winner', horses -> (result[1] - 1) ->> 'name', 'odds', horses -> (result[1] - 1) -> 'odds') order by id desc), '[]')
    into hist
    from (select * from races where id < cur and settled order by id desc limit 8) z;

  -- 直前のレースの自分の結果
  select coalesce(jsonb_agg(jsonb_build_object('horse', horse, 'kind', kind, 'amount', amount, 'payout', payout) order by id), '[]')
    into prev from race_bets where race_id = cur - 1 and user_id = u;

  return jsonb_build_object(
    'now_ms', floor(extract(epoch from clock_timestamp()) * 1000),
    'race', jsonb_build_object(
      'id', cur, 'start_ms', cur * 180000, 'bet_ms', 120000, 'run_ms', 30000, 'round_ms', 180000,
      'horses', (select jsonb_agg(h - 'str') from jsonb_array_elements(r.horses) h),
      'result', case when shown then to_jsonb(r.result) end,
      'seed',   case when shown then r.seed end),
    'pool', pool, 'feed', feed, 'mine', mine, 'prev', prev, 'history', hist,
    'balance', _bal(u));
end $$;

-- ---------------------------------------------------------------------
-- 実行権限：内部用（_ではじまる）は画面から呼べないようにする
-- ---------------------------------------------------------------------
do $$
declare
  f record;
  race_open constant boolean := false;  -- 競馬を公開するときは true にして Run（index.html の RACE_ON も true に）
begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname in (
            '_me','_rint','_take','_give','_bal','_log','_card','_cards','_slot_sym',
            '_hilo_json','_bj_total','_bj_json','_bj_finish','_race_cur','_race_get','_race_settle',
            'ensure_profile','my_profile','set_nickname','leaderboard','my_history','slot_spin',
            'roulette_spin','hilo_state','hilo_start','hilo_guess','hilo_cashout','bj_state',
            'bj_start','bj_hit','bj_stand','bj_double','race_bet','race_state') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if left(f.proname, 1) = '_' or (not race_open and f.proname in ('race_bet', 'race_state')) then
      execute format('revoke all on function %s from authenticated', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
