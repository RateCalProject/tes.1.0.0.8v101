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

-- 税と給付金 ----------------------------------------------------------
-- 設定（テスト用の時計 fake_now など。ふだんは空のまま）
create table if not exists public.app_settings (
  key   text primary key,
  value text
);

-- 国庫（1行だけ）。balance がマイナスのときは国債（国の借金）
create table if not exists public.treasury (
  id            int primary key default 1 check (id = 1),
  balance       bigint not null default 0,
  casino_total  bigint not null default 0,
  tax_total     bigint not null default 0,
  benefit_total bigint not null default 0
);
-- はじめて作るときは、これまでのカジノのもうけを国庫に入れておく
insert into public.treasury(id, balance, casino_total)
select 1, s, s from (select coalesce(sum(bet - payout), 0)::bigint s from public.tx_log
                      where game in ('slot','roulette','hilo','blackjack','race')) z
on conflict (id) do nothing;

-- 締めた月
create table if not exists public.tax_months (
  month        int primary key,          -- 例: 202610
  processed    boolean not null default false,
  processed_at timestamptz
);

-- 申告書（1人1か月1枚）
create table if not exists public.tax_returns (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  month       int not null,
  declared    bigint,                     -- 申告した所得（null = 申告なし）
  filed_at    timestamptz,
  true_income bigint,                     -- 締めのときに記録から出した本当の所得
  tax_due     bigint not null default 0,  -- 納める額（加算税・延滞金こみ）
  tax_paid    bigint not null default 0,
  penalty     bigint not null default 0,  -- 加算税・延滞金の合計
  ontime      boolean not null default false,
  audited     boolean not null default false,
  evasion     boolean not null default false,
  status      text,
  benefit     bigint not null default 0,
  primary key (user_id, month)
);

-- 役所からのお知らせ
create table if not exists public.notices (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  body       text not null,
  seen       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notices_user_idx on public.notices(user_id, id desc);
create index if not exists tx_log_user_time_idx on public.tx_log(user_id, created_at);

-- 画面から直接テーブルを読み書きさせない（全部 下の関数を通す）
alter table public.profiles     enable row level security;
alter table public.tx_log       enable row level security;
alter table public.hilo_games   enable row level security;
alter table public.bj_games     enable row level security;
alter table public.races        enable row level security;
alter table public.race_bets    enable row level security;
alter table public.app_settings enable row level security;
alter table public.treasury     enable row level security;
alter table public.tax_months   enable row level security;
alter table public.tax_returns  enable row level security;
alter table public.notices      enable row level security;
revoke all on public.profiles, public.tx_log, public.hilo_games, public.bj_games,
              public.races, public.race_bets, public.app_settings, public.treasury,
              public.tax_months, public.tax_returns, public.notices from anon, authenticated;

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

-- いまの時刻（app_settings に fake_now があればその時刻。テスト用）
create or replace function public._now() returns timestamptz
language sql stable set search_path = public as $$
  select coalesce((select value::timestamptz from app_settings where key = 'fake_now'), now())
$$;
alter table public.profiles alter column created_at set default public._now();
alter table public.tx_log   alter column created_at set default public._now();
alter table public.notices  alter column created_at set default public._now();

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

-- 払い戻す（税金の滞納があると、払い戻しから差し押さえる）
create or replace function public._give(u uuid, amt bigint) returns bigint
language plpgsql set search_path = public as $$
declare b bigint;
begin
  update profiles set balance = balance + greatest(amt, 0) where id = u returning balance into b;
  if amt > 0 and exists (select 1 from tax_returns t join tax_months mm on mm.month = t.month and mm.processed
                          where t.user_id = u and t.tax_due > t.tax_paid) then
    perform _pay_tax(u, amt, true, 'garnish');
    b := _bal(u);
  end if;
  return b;
end $$;

create or replace function public._bal(u uuid) returns bigint
language sql stable set search_path = public as $$ select balance from profiles where id = u $$;

-- 記録する。ゲームのときは、カジノのもうけ（賭け金 − 払い戻し）を国庫に入れる
create or replace function public._log(u uuid, g text, bet bigint, pay bigint, d jsonb) returns void
language plpgsql set search_path = public as $$
begin
  insert into tx_log(user_id, game, bet, payout, balance_after, detail)
  values (u, g, bet, pay, (select balance from profiles where id = u), d);
  if g in ('slot','roulette','hilo','blackjack','race') then
    update treasury set balance = balance + (bet - pay), casino_total = casino_total + (bet - pay) where id = 1;
  end if;
end $$;

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
  -- 締めの日を過ぎていたら、税の締め（調査・差し押さえ・給付金）をここで行う
  -- 万一失敗してもログインは止めない
  begin
    perform _tax_tick();
  exception when others then
    raise warning 'tax tick failed: %', sqlerrm;
  end;
  return (select jsonb_build_object('nickname', nickname, 'balance', balance, 'tax', _tax_badge(u))
            from profiles where id = u);
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
-- 税と給付金（ゲームの中だけの税です。実際の税金とは関係ありません）
--   1年 = 1か月（日本時間）。毎月1日〜15日に前の月の分を申告し、16日に締める
--   所得 = その月の（払い戻し − 賭け金）。マイナスなら0。初回の配布と給付金はかからない
--   税額 = 基礎控除500を引いた残りに 〜2,000:5% 〜10,000:10% 〜50,000:20% 〜200,000:33% それ以上:45%
--   税務調査：申告した人から 10% ＋ ごまかしの大きさ×80% の確率で。見つかると不足分＋重加算税35%
--   申告なし：記録から計算して無申告加算税15%。期限までに納めない分：延滞金10%＋残高から差し押さえ
--   給付金500：期限内に申告して納め、脱税が見つからず、滞納がない人（その月にいた人だけ）
-- ---------------------------------------------------------------------
create or replace function public._month_of(ts timestamptz) returns int
language sql stable as $$ select to_char(ts at time zone 'Asia/Tokyo', 'YYYYMM')::int $$;

create or replace function public._month_start(m int) returns timestamptz
language sql stable as $$ select make_timestamptz(m / 100, m % 100, 1, 0, 0, 0, 'Asia/Tokyo') $$;

create or replace function public._next_month(m int) returns int
language sql immutable as $$ select case when m % 100 = 12 then (m / 100 + 1) * 100 + 1 else m + 1 end $$;

create or replace function public._prev_month(m int) returns int
language sql immutable as $$ select case when m % 100 = 1 then (m / 100 - 1) * 100 + 12 else m - 1 end $$;

create or replace function public._jday(ts timestamptz) returns int
language sql stable as $$ select extract(day from ts at time zone 'Asia/Tokyo')::int $$;

create or replace function public._dlabel(ts timestamptz) returns text
language sql stable as $$ select to_char(ts at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日"') $$;

create or replace function public._fmt(n bigint) returns text
language sql immutable as $$ select to_char(n, 'FM999,999,999,999,990') $$;

-- 税額（累進課税）
create or replace function public._tax(inc bigint) returns bigint
language plpgsql immutable as $$
declare t numeric := greatest(coalesce(inc, 0) - 500, 0);
begin
  return floor(
      least(t, 2000) * 0.05
    + greatest(least(t, 10000)  - 2000,   0) * 0.10
    + greatest(least(t, 50000)  - 10000,  0) * 0.20
    + greatest(least(t, 200000) - 50000,  0) * 0.33
    + greatest(t - 200000, 0) * 0.45);
end $$;

-- その月の所得（記録から）
create or replace function public._income(u uuid, m int) returns bigint
language sql stable set search_path = public as $$
  select greatest(coalesce(sum(payout - bet), 0), 0)::bigint from tx_log
   where user_id = u and game in ('slot','roulette','hilo','blackjack','race')
     and created_at >= _month_start(m) and created_at < _month_start(_next_month(m))
$$;

create or replace function public._notice(u uuid, t text) returns void
language sql set search_path = public as $$ insert into notices(user_id, body) values (u, t) $$;

-- 滞納（締めたあとの月で、まだ納めていない額）
create or replace function public._debt(u uuid) returns bigint
language sql stable set search_path = public as $$
  select coalesce(sum(t.tax_due - t.tax_paid), 0)::bigint
    from tax_returns t join tax_months mm on mm.month = t.month and mm.processed
   where t.user_id = u and t.tax_due > t.tax_paid
$$;

-- 残高から税を納める（古い月から）。only_overdue = 滞納の分だけに充てる。納めた額を返す
create or replace function public._pay_tax(u uuid, maxamt bigint, only_overdue boolean, kind text) returns bigint
language plpgsql set search_path = public as $$
declare rest bigint := least(greatest(coalesce(maxamt, 0), 0), coalesce(_bal(u), 0)); r record; x bigint; total bigint := 0;
begin
  if rest <= 0 then return 0; end if;
  for r in select t.month, t.tax_due - t.tax_paid as owe
             from tax_returns t left join tax_months mm on mm.month = t.month
            where t.user_id = u and t.tax_due > t.tax_paid and (not only_overdue or coalesce(mm.processed, false))
            order by t.month
            for update of t loop
    exit when rest <= 0;
    x := least(rest, r.owe);
    update tax_returns set tax_paid = tax_paid + x where user_id = u and month = r.month;
    rest := rest - x; total := total + x;
  end loop;
  if total > 0 then
    update profiles set balance = balance - total where id = u;
    update treasury set balance = balance + total, tax_total = tax_total + total where id = 1;
    perform _log(u, kind, total, 0, null);
  end if;
  return total;
end $$;

-- 1か月分を締める（税務調査・無申告の決定・延滞金・差し押さえ・給付金）
create or replace function public._process_month(m int) returns void
language plpgsql set search_path = public as $$
declare
  p record; r tax_returns; tru bigint; f numeric; ctax bigint; dtax bigint; x bigint; pen bigint;
  unpaid bigint; refund bigint; got bigint;
  mend timestamptz := _month_start(_next_month(m));
  lbl text := (m % 100)::text || '月分';
begin
  insert into tax_months(month) values (m) on conflict (month) do nothing;
  if (select processed from tax_months where month = m for update) then return; end if;

  for p in select id from profiles where created_at < mend order by created_at loop
    tru := _income(p.id, m);
    select * into r from tax_returns where user_id = p.id and month = m for update;
    if found and r.declared is not null then
      -- 申告した人
      unpaid := greatest(r.tax_due - r.tax_paid, 0);
      update tax_returns set true_income = tru, ontime = (unpaid = 0) where user_id = p.id and month = m;
      f := case when tru > 0 and r.declared < tru then (tru - r.declared)::numeric / tru else 0 end;
      if random() < 0.10 + 0.80 * f then
        ctax := _tax(tru); dtax := _tax(r.declared);
        if ctax > dtax then
          x := ctax - dtax; pen := floor(x * 0.35);
          update tax_returns set audited = true, evasion = true, status = 'evasion',
                 tax_due = tax_due + x + pen, penalty = penalty + pen
           where user_id = p.id and month = m;
          perform _notice(p.id, format('【税務調査】%s：申告より %s 多い所得が見つかりました。不足分 %s ＋ 重加算税 %s を追徴します。この月の給付金はもらえません。',
                                       lbl, _fmt(tru - r.declared), _fmt(x), _fmt(pen)));
        elsif dtax > ctax then
          x := dtax - ctax;
          update tax_returns set audited = true, status = 'refund', tax_due = tax_due - x
           where user_id = p.id and month = m
          returning greatest(tax_paid - tax_due, 0) into refund;
          if refund > 0 then
            update tax_returns set tax_paid = tax_due where user_id = p.id and month = m;
            update profiles set balance = balance + refund where id = p.id;
            update treasury set balance = balance - refund, tax_total = tax_total - refund where id = 1;
            perform _log(p.id, 'refund', 0, refund, jsonb_build_object('month', m));
          end if;
          perform _notice(p.id, format('【税務調査】%s：所得を多く申告していたので、税額を %s 減らしました%s。',
                                       lbl, _fmt(x), case when refund > 0 then '（' || _fmt(refund) || ' を還付）' else '' end));
        else
          update tax_returns set audited = true, status = 'audit_ok' where user_id = p.id and month = m;
          perform _notice(p.id, format('【税務調査】%s：問題ありませんでした。', lbl));
        end if;
      end if;
      if unpaid > 0 then
        pen := floor(unpaid * 0.10);
        update tax_returns set tax_due = tax_due + pen, penalty = penalty + pen where user_id = p.id and month = m;
        perform _notice(p.id, format('%sの税金 %s が期限までに納められていなかったので、延滞金 %s がつきました。この月の給付金はもらえません。',
                                     lbl, _fmt(unpaid), _fmt(pen)));
      end if;
    else
      -- 申告しなかった人：税がかかるなら税務署が決める
      ctax := _tax(tru);
      if ctax > 0 then
        pen := floor(ctax * 0.15);
        insert into tax_returns(user_id, month, true_income, tax_due, penalty, status)
        values (p.id, m, tru, ctax + pen, pen, 'no_filing')
        on conflict (user_id, month) do update
          set true_income = excluded.true_income, tax_due = excluded.tax_due,
              penalty = excluded.penalty, status = excluded.status;
        perform _notice(p.id, format('【決定】%sの申告がなかったので、税務署が所得 %s として税額 %s ＋ 無申告加算税 %s を決めました。',
                                     lbl, _fmt(tru), _fmt(ctax), _fmt(pen)));
      end if;
    end if;
  end loop;

  update tax_months set processed = true, processed_at = now() where month = m;

  -- 期限までに納められていない分は、残高から差し押さえ
  for r in select * from tax_returns where month = m and tax_due > tax_paid loop
    got := _pay_tax(r.user_id, _bal(r.user_id), true, 'garnish');
    if got > 0 then
      perform _notice(r.user_id, format('未納の税金として、残高から %s を差し押さえました。', _fmt(got)));
    end if;
    if _debt(r.user_id) > 0 then
      perform _notice(r.user_id, format('まだ %s の滞納があります。当たりが出ると自動で差し押さえられます。', _fmt(_debt(r.user_id))));
    end if;
  end loop;

  -- 給付金：期限内に申告して納め、脱税が見つからず、滞納がない人
  for r in select * from tax_returns where month = m and declared is not null and ontime and not evasion loop
    if _debt(r.user_id) = 0 then
      update profiles set balance = balance + 500 where id = r.user_id;
      update treasury set balance = balance - 500, benefit_total = benefit_total + 500 where id = 1;
      update tax_returns set benefit = 500 where user_id = r.user_id and month = m;
      perform _log(r.user_id, 'benefit', 0, 500, jsonb_build_object('month', m));
      perform _notice(r.user_id, format('%sの給付金 500 が入りました。', lbl));
    else
      perform _notice(r.user_id, format('%sの給付金は、滞納があるためもらえませんでした。', lbl));
    end if;
  end loop;
end $$;

-- 締めの日を過ぎた月があれば締める（だれかが開いたときに動く）
create or replace function public._tax_tick() returns void
language plpgsql set search_path = public as $$
declare lastm int := _prev_month(_month_of(_now() - interval '15 days')); m int;
begin
  if exists (select 1 from tax_months where month = lastm and processed) then return; end if;
  perform pg_advisory_xact_lock(20261016);
  select _month_of(min(created_at)) into m from profiles;
  if m is null then return; end if;
  while m <= lastm loop
    if not coalesce((select processed from tax_months where month = m), false) then
      perform _process_month(m);
    end if;
    m := _next_month(m);
  end loop;
end $$;

-- 役所タブに印をつけるための情報
create or replace function public._tax_badge(u uuid) returns jsonb
language plpgsql set search_path = public as $$
declare nowt timestamptz := _now(); cm int := _month_of(nowt);
begin
  return jsonb_build_object(
    'notices', (select count(*) from notices where user_id = u and not seen),
    'filing_open', _jday(nowt) <= 15 and (select created_at from profiles where id = u) < _month_start(cm),
    'filed', exists (select 1 from tax_returns where user_id = u and month = _prev_month(cm) and declared is not null),
    'debt', _debt(u));
end $$;

-- 役所の画面
create or replace function public.tax_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _me(); nowt timestamptz; cm int; fm int; d int; created timestamptz; r tax_returns;
  filing jsonb; notes jsonb; rets jsonb; topm int; top jsonb; tr treasury; inc bigint; dl timestamptz; nx timestamptz;
begin
  perform _tax_tick();
  nowt := _now(); cm := _month_of(nowt); fm := _prev_month(cm); d := _jday(nowt);
  select created_at into created from profiles where id = u;
  if created is null then raise exception 'ログインしなおしてください'; end if;

  if d <= 15 and created < _month_start(cm) then
    select * into r from tax_returns where user_id = u and month = fm;
    dl := _month_start(cm) + interval '15 days';
    filing := jsonb_build_object(
      'month', fm, 'deadline', _dlabel(dl - interval '1 day'),
      'days_left', ceil(extract(epoch from dl - nowt) / 86400)::int,
      'recorded', _income(u, fm),
      'filed', r.declared is not null, 'declared', r.declared,
      'tax_due', coalesce(r.tax_due, 0), 'tax_paid', coalesce(r.tax_paid, 0));
  end if;
  nx := _month_start(_next_month(cm));
  inc := _income(u, cm);

  select coalesce(jsonb_agg(jsonb_build_object('body', body, 'new', not seen,
           'at', _dlabel(created_at)) order by id desc), '[]'::jsonb) into notes
    from (select * from notices where user_id = u order by id desc limit 20) z;
  update notices set seen = true where user_id = u and not seen;

  select coalesce(jsonb_agg(jsonb_build_object('month', t.month, 'declared', t.declared,
           'true_income', case when coalesce(mm.processed, false) then t.true_income end,
           'tax_due', t.tax_due, 'tax_paid', t.tax_paid, 'penalty', t.penalty, 'status', t.status,
           'audited', t.audited, 'evasion', t.evasion, 'benefit', t.benefit,
           'processed', coalesce(mm.processed, false)) order by t.month desc), '[]'::jsonb) into rets
    from (select * from tax_returns where user_id = u order by month desc limit 12) t
    left join tax_months mm on mm.month = t.month;

  select max(month) into topm from tax_months where processed;
  select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'tax', t.tax_paid) order by t.tax_paid desc), '[]'::jsonb) into top
    from (select * from tax_returns where month = topm and tax_paid > 0 order by tax_paid desc limit 10) t
    join profiles p on p.id = t.user_id;

  select * into tr from treasury where id = 1;

  return jsonb_build_object(
    'current', jsonb_build_object('month', cm, 'income', inc, 'tax', _tax(inc)),
    'filing', filing,
    'next', jsonb_build_object('month', cm, 'from', _dlabel(nx), 'to', _dlabel(nx + interval '14 days')),
    'debt', _debt(u),
    'returns', rets, 'notices', notes,
    'treasury', jsonb_build_object('balance', coalesce(tr.balance, 0), 'casino', coalesce(tr.casino_total, 0),
                                   'tax', coalesce(tr.tax_total, 0), 'benefit', coalesce(tr.benefit_total, 0)),
    'top', top, 'top_month', topm,
    'balance', _bal(u));
end $$;

-- 申告する（期限内なら何度でも出し直せる）
create or replace function public.tax_file(p_declared bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); nowt timestamptz; cm int; fm int; r tax_returns; refund bigint;
begin
  perform _tax_tick();
  nowt := _now(); cm := _month_of(nowt); fm := _prev_month(cm);
  if _jday(nowt) > 15 then
    raise exception '今は申告の期間ではありません（毎月1日〜15日に、前の月の分を申告します）';
  end if;
  if (select created_at from profiles where id = u) >= _month_start(cm) then
    raise exception '%月分の申告はありません（%月にはまだ登録していませんでした）', fm % 100, fm % 100;
  end if;
  if p_declared is null or p_declared < 0 or p_declared > 1000000000000 then
    raise exception '所得は0以上の数字で書いてください';
  end if;
  insert into tax_returns(user_id, month, declared, filed_at, tax_due, status)
  values (u, fm, p_declared, nowt, _tax(p_declared), 'filed')
  on conflict (user_id, month) do update
    set declared = excluded.declared, filed_at = excluded.filed_at, tax_due = excluded.tax_due, status = 'filed'
  returning * into r;
  -- 出し直して税額が減ったら、納めすぎた分を返す
  if r.tax_paid > r.tax_due then
    refund := r.tax_paid - r.tax_due;
    update tax_returns set tax_paid = tax_due where user_id = u and month = fm;
    update profiles set balance = balance + refund where id = u;
    update treasury set balance = balance - refund, tax_total = tax_total - refund where id = 1;
    perform _log(u, 'refund', 0, refund, jsonb_build_object('month', fm));
  end if;
  return tax_state();
end $$;

-- 納める（滞納の古い月から、今の申告の分まで、残高でまかなえるだけ）
create or replace function public.tax_pay() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); got bigint;
begin
  perform _tax_tick();
  got := _pay_tax(u, _bal(u), false, 'tax');
  if got = 0 then raise exception '納める税金がないか、AiliNaXが足りません'; end if;
  return tax_state() || jsonb_build_object('paid', got);
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
            'bj_start','bj_hit','bj_stand','bj_double','race_bet','race_state',
            '_now','_month_of','_month_start','_next_month','_prev_month','_jday','_dlabel','_fmt',
            '_tax','_income','_notice','_debt','_pay_tax','_process_month','_tax_tick','_tax_badge',
            'tax_state','tax_file','tax_pay') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if left(f.proname, 1) = '_' or (not race_open and f.proname in ('race_bet', 'race_state')) then
      execute format('revoke all on function %s from authenticated', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
