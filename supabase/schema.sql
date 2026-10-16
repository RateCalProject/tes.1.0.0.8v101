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

-- 競馬 ----------------------------------------------------------------
-- 前の版の競馬（3分ごとのレース）は使わないので消す
drop function if exists public.race_bet(bigint, int, text, bigint);
drop function if exists public.race_state();
drop function if exists public._race_settle(bigint);
drop function if exists public._race_get(bigint);
drop function if exists public._race_cur();
drop table if exists public.race_bets;
drop table if exists public.races;

-- 競馬場
create table if not exists public.keiba_venues (
  id       int primary key,
  name     text not null,
  turn     text not null,                 -- 右 / 左
  straight int not null,                  -- 最後の直線（m）
  slope    boolean not null default false,-- ゴール前の坂
  circuit  int not null,                  -- 1周（m）
  front    numeric not null default 0,    -- 前に行く馬の有利さ（＋なら前が有利）
  turf_d   int[] not null,                -- ふだんのレースの芝の距離
  dirt_d   int[] not null                 -- ふだんのレースのダートの距離
);
-- 騎手
create table if not exists public.keiba_jockeys (
  id    int primary key,
  name  text not null,
  skill numeric not null
);
-- 名前のついたレース（名前・距離・芝ダートは、ここを書きかえればあとから変えられる）
create table if not exists public.keiba_names (
  kind     text not null,                 -- g1（日曜）/ sat（土曜）/ wd（平日）
  idx      int not null,                  -- 日曜・土曜：その月の何回目か(0〜4)　平日：曜日(1=月〜5=金)
  name     text not null,
  grade    text not null,                 -- G1 / G2 / G3 / L / OP
  surface  text not null,                 -- 芝 / ダ
  dist     int not null,
  cond     text not null default '3up',   -- 3up=3歳以上 3yo=3歳
  handicap boolean not null default false,
  primary key (kind, idx)
);
-- 馬
create table if not exists public.keiba_horses (
  id         serial primary key,
  name       text not null unique,
  sex        text not null,               -- 牡 / 牝 / セ
  born       int not null,                -- 生まれた「年」（年*12+月の通し番号。1年＝1か月）
  coat       int not null,                -- 毛色
  silk1      text not null,
  silk2      text not null,
  silk_pat   int not null,                -- 勝負服の模様
  ability    numeric not null,            -- 力（見せない）
  style      int not null,                -- 0逃げ 1先行 2差し 3追込
  best_dist  int not null,
  dist_width int not null,
  turf       numeric not null,            -- 1に近いほど芝が得意、0に近いほどダートが得意
  heavy      numeric not null,            -- 重い馬場：＋得意 −苦手
  body       int not null,                -- 馬体重
  class      int not null default 0,      -- 0未勝利 1〜3勝クラス 4オープン
  wins       int not null default 0,
  starts     int not null default 0,
  prize      bigint not null default 0,   -- 獲得賞金（万円。雰囲気だけ）
  graded     int not null default 0,      -- 重賞の勝ち数
  retired    boolean not null default false,
  last_day   date
);
create index if not exists keiba_horses_pick_idx on public.keiba_horses(class, retired);
-- レース
create table if not exists public.keiba_races (
  id        bigint primary key,           -- 日付(YYYYMMDD)*100 ＋ その日の番号(1〜29)
  day       date not null,
  no        int not null,
  post      timestamptz not null,         -- 発走時刻
  venue     int not null references public.keiba_venues(id),
  rnum      int not null,                 -- その競馬場の第◯R
  name      text not null,
  grade     text,                         -- null / OP / L / G3 / G2 / G1
  cls       int,
  cond      text not null,
  surface   text not null,
  dist      int not null,
  going     text not null,
  weather   text not null,
  tier      text not null,                -- normal / graded / g1（払戻率）
  handicap  boolean not null default false,
  pace      text,
  finish_ms int,
  settled   boolean not null default false
);
create index if not exists keiba_races_day_idx on public.keiba_races(day, no);
create index if not exists keiba_races_open_idx on public.keiba_races(settled, post);
-- 出走馬
create table if not exists public.keiba_entries (
  race_id    bigint not null references public.keiba_races(id) on delete cascade,
  uma        int not null,
  waku       int not null,
  horse_id   int not null references public.keiba_horses(id),
  jockey     int not null references public.keiba_jockeys(id),
  age        int not null,
  kinryo     numeric not null,
  body       int not null,
  body_diff  int not null,
  r_pub      numeric not null,            -- みんなの見立て（オッズのもと）
  r_true     numeric not null,            -- 本当の力（調子・ペースこみ。見せない）
  w          numeric not null default 0,
  odds_win   numeric,
  odds_place numeric,
  ninki      int,
  pos        int,
  time_ms    int,
  margin     text,
  last3f     numeric,
  shape      numeric,
  lane       numeric,
  primary key (race_id, uma)
);
create index if not exists keiba_entries_horse_idx on public.keiba_entries(horse_id, race_id desc);
-- 馬券
create table if not exists public.keiba_tickets (
  id         bigserial primary key,
  race_id    bigint not null references public.keiba_races(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('tan','fuku','waku','umaren','wide','umatan','trio','trifecta')),
  sel        int[] not null,
  amount     bigint not null check (amount > 0),
  odds       numeric not null,
  payout     bigint,
  created_at timestamptz not null default now()
);
create index if not exists keiba_tickets_race_idx on public.keiba_tickets(race_id);
create index if not exists keiba_tickets_user_idx on public.keiba_tickets(user_id, race_id desc);

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
-- 悪質なごまかしの没収（あとから足した列）
alter table public.tax_returns add column if not exists malicious   boolean not null default false;
alter table public.tax_returns add column if not exists confiscated bigint  not null default 0;
alter table public.treasury    add column if not exists confiscated_total bigint not null default 0;
create index if not exists tx_log_user_time_idx on public.tx_log(user_id, created_at);

-- 画面から直接テーブルを読み書きさせない（全部 下の関数を通す）
alter table public.profiles     enable row level security;
alter table public.tx_log       enable row level security;
alter table public.hilo_games   enable row level security;
alter table public.bj_games     enable row level security;
alter table public.keiba_venues  enable row level security;
alter table public.keiba_jockeys enable row level security;
alter table public.keiba_names   enable row level security;
alter table public.keiba_horses  enable row level security;
alter table public.keiba_races   enable row level security;
alter table public.keiba_entries enable row level security;
alter table public.keiba_tickets enable row level security;
alter table public.app_settings enable row level security;
alter table public.treasury     enable row level security;
alter table public.tax_months   enable row level security;
alter table public.tax_returns  enable row level security;
alter table public.notices      enable row level security;
revoke all on public.profiles, public.tx_log, public.hilo_games, public.bj_games,
              public.app_settings, public.treasury, public.tax_months, public.tax_returns, public.notices,
              public.keiba_venues, public.keiba_jockeys, public.keiba_names, public.keiba_horses,
              public.keiba_races, public.keiba_entries, public.keiba_tickets from anon, authenticated;

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
alter table public.keiba_tickets alter column created_at set default public._now();

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
-- 税と給付金（ゲームの中だけの税です。実際の税金とは関係ありません）
--   1年 = 1か月（日本時間）。毎月1日〜15日に前の月の分を申告し、16日に締める
--   所得 = その月の（払い戻し − 賭け金）。マイナスなら0。初回の配布と給付金はかからない
--   税額 = 基礎控除500を引いた残りに 〜2,000:5% 〜10,000:10% 〜50,000:20% 〜200,000:33% それ以上:45%
--   税務調査：申告した人から 10% ＋ ごまかしの大きさ×80% の確率で。見つかると不足分＋重加算税35%
--   悪質（半分以上隠した／隠した所得が10,000以上／前にも見つかった）なら、税を納めたあとの残高の7割を没収
--   申告なし：記録から計算して無申告加算税15%。期限までに納めない分：延滞金10%＋残高から差し押さえ
--   給付金500：期限内に申告して納め、脱税が見つからず、滞納がなく、所持金5,000以下の人（その月にいた人だけ）
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

-- 所持金（残高＋遊んでいる途中の賭け金）
create or replace function public._assets(u uuid) returns bigint
language sql stable set search_path = public as $$
  select coalesce((select balance from profiles where id = u), 0)
       + coalesce((select bet from hilo_games where user_id = u), 0)
       + coalesce((select bet from bj_games where user_id = u), 0)
       + coalesce((select sum(amount) from keiba_tickets where user_id = u and payout is null), 0)
$$;

-- 1か月分を締める（税務調査・無申告の決定・延滞金・差し押さえ・没収・給付金）
create or replace function public._process_month(m int) returns void
language plpgsql set search_path = public as $$
declare
  p record; r tax_returns; tru bigint; f numeric; ctax bigint; dtax bigint; x bigint; pen bigint;
  unpaid bigint; refund bigint; got bigint; mal boolean; rep boolean; why text; hidden bigint; amt bigint;
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
          hidden := tru - r.declared;
          -- 悪質：半分以上隠した／隠した所得が10,000以上／前にも見つかったことがある
          rep := exists (select 1 from tax_returns where user_id = p.id and month < m and evasion);
          mal := f >= 0.5 or hidden >= 10000 or rep;
          why := concat_ws('・',
                   case when f >= 0.5 then '所得の半分以上を隠していた' end,
                   case when hidden >= 10000 then '隠した所得が10,000以上' end,
                   case when rep then '前にもごまかしが見つかっている' end);
          update tax_returns set audited = true, evasion = true, malicious = mal,
                 status = case when mal then 'malicious' else 'evasion' end,
                 tax_due = tax_due + x + pen, penalty = penalty + pen
           where user_id = p.id and month = m;
          perform _notice(p.id, format('【税務調査】%s：申告より %s 多い所得が見つかりました。不足分 %s ＋ 重加算税 %s を追徴します。%sこの月の給付金はもらえません。',
                                       lbl, _fmt(hidden), _fmt(x), _fmt(pen),
                                       case when mal then format('悪質なごまかし（%s）と判断したので、税を納めたあとの残高の7割を没収します。', why) else '' end));
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

  -- 悪質なごまかし：税を納めたあとの残高の7割を没収（国庫へ）
  for r in select * from tax_returns where month = m and malicious loop
    amt := floor(_bal(r.user_id) * 0.70);
    if amt > 0 then
      update profiles set balance = balance - amt where id = r.user_id;
      update treasury set balance = balance + amt, confiscated_total = confiscated_total + amt where id = 1;
      update tax_returns set confiscated = amt where user_id = r.user_id and month = m;
      perform _log(r.user_id, 'confiscate', amt, 0, jsonb_build_object('month', m));
      perform _notice(r.user_id, format('【没収】%sの悪質なごまかしにより、残高の7割にあたる %s を没収しました。', lbl, _fmt(amt)));
    end if;
  end loop;

  -- 給付金：期限内に申告して納め、脱税が見つからず、滞納がなく、所持金が5,000以下の人
  for r in select * from tax_returns where month = m and declared is not null and ontime and not evasion loop
    if _debt(r.user_id) > 0 then
      perform _notice(r.user_id, format('%sの給付金は、滞納があるためもらえませんでした。', lbl));
    elsif _assets(r.user_id) > 5000 then
      perform _notice(r.user_id, format('%sの給付金は、所持金が5,000をこえているのでありません。', lbl));
    else
      update profiles set balance = balance + 500 where id = r.user_id;
      update treasury set balance = balance - 500, benefit_total = benefit_total + 500 where id = 1;
      update tax_returns set benefit = 500 where user_id = r.user_id and month = m;
      perform _log(r.user_id, 'benefit', 0, 500, jsonb_build_object('month', m));
      perform _notice(r.user_id, format('%sの給付金 500 が入りました。', lbl));
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
           'malicious', t.malicious, 'confiscated', t.confiscated,
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
                                   'tax', coalesce(tr.tax_total, 0), 'benefit', coalesce(tr.benefit_total, 0),
                                   'confiscated', coalesce(tr.confiscated_total, 0)),
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
-- 競馬
--   ふだんのレース：毎日 16:30・17:30・18:30・19:30 から7レースずつ（8分おき）。回ごとに競馬場が変わる
--   メインレース：毎日 20:30（平日オープン特別・土曜G2/G3・日曜G1）
--   同じ馬が走りつづける。勝つとクラスが上がる。1年＝1か月で年をとり、8歳で引退
--   オッズは買った時点で決まる固定オッズ。人気は「みんなの見立て」で、調子・ペース・馬体重の増減は入っていない
--   払戻率：ふだん 単複75% 枠連・馬連・ワイド72.5% 馬単・3連複70% 3連単67.5%
--           重賞・オープン JRAと同じ（80/77.5/75/72.5%）　G1 85/82.5/80/77.5%
-- ---------------------------------------------------------------------
insert into public.keiba_venues(id, name, turn, straight, slope, circuit, front, turf_d, dirt_d) values
  -- 16:30 中京 / 17:30 京都 / 18:30 府中 / 19:30 京都 / 20:30 府中（メイン）
  (1, '中京', '左', 412, true,  1705,  0.3, '{1200,1400,1600,2000,2200}', '{1200,1400,1800,1900}'),
  (2, '京都', '右', 404, true,  1894,  0.1, '{1200,1400,1600,1800,2000,2200,2400,3000,3200}', '{1200,1400,1800,1900}'),
  (3, '府中', '左', 525, true,  2083, -1.0, '{1400,1600,1800,2000,2400}', '{1300,1400,1600,2100}'),
  (4, '京都', '右', 404, true,  1894,  0.1, '{1200,1400,1600,1800,2000,2200,2400,3000,3200}', '{1200,1400,1800,1900}'),
  (5, '府中', '左', 525, true,  2083, -1.0, '{1600,2000,2400}', '{1600,2100}')
on conflict (id) do update set name = excluded.name, turn = excluded.turn, straight = excluded.straight,
  slope = excluded.slope, circuit = excluded.circuit, front = excluded.front, turf_d = excluded.turf_d, dirt_d = excluded.dirt_d;

insert into public.keiba_jockeys(id, name, skill) values
  (1,'早瀬',68),(2,'桐生',66),(3,'浅見',63),(4,'葛城',62),(5,'御堂',61),(6,'神楽',60),(7,'R.ベルナール',67),
  (8,'L.ヴァレンティ',64),(9,'鳴海',59),(10,'結城',58),(11,'久遠',57),(12,'柏木',57),(13,'霧島',56),
  (14,'天野',55),(15,'篠宮',55),(16,'氷室',54),(17,'真壁',53),(18,'一条',53),(19,'七瀬',52),(20,'東雲',52),
  (21,'白鳥',51),(22,'三雲',50),(23,'雪村',49),(24,'黒江',48),(25,'乙部',47),(26,'若林',46)
on conflict (id) do nothing;

insert into public.keiba_names(kind, idx, name, grade, surface, dist, cond, handicap) values
  ('g1', 0, '白浜スプリントカップ',     'G1', '芝', 1200, '3up', false),
  ('g1', 1, 'AiliNaXダービー',   'G1', '芝', 2400, '3yo', false),
  ('g1', 2, '風見マイルチャンピオン',   'G1', '芝', 1600, '3up', false),
  ('g1', 3, '銀杏ダートクラシック',     'G1', 'ダ', 2000, '3up', false),
  ('g1', 4, 'AiliNaXグランプリ', 'G1', '芝', 2500, '3up', false),
  ('sat', 0, '月影記念',             'G2', '芝', 2000, '3up', false),
  ('sat', 1, '風見ステークス',       'G3', '芝', 1400, '3up', false),
  ('sat', 2, '白浜杯',               'G3', 'ダ', 1800, '3up', false),
  ('sat', 3, '銀杏賞',               'G2', '芝', 1800, '3up', false),
  ('sat', 4, '星降る夜ステークス',   'G3', '芝', 2200, '3up', false),
  ('wd', 1, '夕凪特別',     'OP', '芝', 1600, '3up', false),
  ('wd', 2, '流星ステークス', 'L', '芝', 1400, '3up', false),
  ('wd', 3, '朝霧特別',     'OP', 'ダ', 1400, '3up', true),
  ('wd', 4, '白雲ステークス', 'L', '芝', 2000, '3up', false),
  ('wd', 5, '宵月特別',     'OP', 'ダ', 1600, '3up', false)
on conflict (kind, idx) do nothing;
-- カタカナの「アイリナックス」はやめて AiliNaX に
update public.keiba_names set name = replace(name, 'アイリナックス', 'AiliNaX') where name like '%アイリナックス%';
update public.keiba_races set name = replace(name, 'アイリナックス', 'AiliNaX') where name like '%アイリナックス%';

-- 小さな道具
create or replace function public._kb_norm() returns numeric
language sql volatile as $$ select (sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()))::numeric $$;

create or replace function public._kb_gumbel() returns numeric
language sql volatile as $$ select (-ln(-ln(greatest(random(), 1e-12))))::numeric $$;

create or replace function public._kb_midx(ts timestamptz) returns int
language sql stable as $$
  select (extract(year from ts at time zone 'Asia/Tokyo') * 12 + extract(month from ts at time zone 'Asia/Tokyo'))::int
$$;

create or replace function public._kb_jday(ts timestamptz) returns date
language sql stable as $$ select (ts at time zone 'Asia/Tokyo')::date $$;

create or replace function public._kb_ms(ts timestamptz) returns bigint
language sql stable as $$ select floor(extract(epoch from ts) * 1000)::bigint $$;

-- 年齢による力の出かた（5歳がピーク）
create or replace function public._kb_agef(age int) returns numeric
language sql immutable as $$
  select (case when age <= 2 then 0.93 when age = 3 then 0.97 when age = 4 then 0.995 when age = 5 then 1.0
               when age = 6 then 0.985 when age = 7 then 0.96 else 0.93 end)::numeric
$$;

-- 距離・芝ダートの合いかた
create or replace function public._kb_fit(h public.keiba_horses, surface text, dist int) returns numeric
language sql immutable as $$
  select - least(power((dist - h.best_dist)::numeric / h.dist_width, 2) * 4, 10)
         + case when surface = '芝' then (h.turf - 0.5) else (0.5 - h.turf) end * 8
$$;

-- 馬の名前（カタカナ9文字まで）
create or replace function public._kb_name() returns text
language plpgsql volatile set search_path = public as $$
declare
  a text[] := array['アオ','シロ','クロ','ハヤ','カゼ','ソラ','ホシ','ツキ','ユメ','ミライ','ヒカリ','ナギ','ウミ',
    'ハル','ナツ','アキ','フユ','ミナト','ツバサ','イナズマ','ルリ','コハク','ギン','ベニ','シオン','リン','セイ',
    'ライ','ジン','レイ','カイ','トキ','ニジ','テン','ミズ','ブルー','シルバー','クリスタル','スカイ','ノーブル',
    'ミスティ','ルナ','ステラ','アスター','リバー','ウィンド','ブレイブ','ハッピー','ラッキー','ドリーム','ロイヤル',
    'マジック','ブライト','サニー','グラン','エース','ネオ','ベル','ミント','ショコラ','ノア','エル','ルカ','フジ'];
  b text[] := array['ハヤテ','カゼ','ボシ','ミチ','ノオー','オー','ヒメ','ジョー','マル','タロウ','ナデシコ','ツバキ',
    'カグラ','ムサシ','ヤマト','ボーイ','ガール','スター','ライト','ロード','キング','クイーン','ダンサー','ランナー',
    'ダッシュ','ジェット','ロケット','ブリーズ','ストーム','サンダー','フレア','ノヴァ','ルビー','パール','オパール',
    'ミント','モカ','ラテ','リリー','ローズ','ハート','ソウル','ビート','リズム','メロディ','ソング','ワルツ','ステップ',
    'フライト','ウイング','アロー','ブレード','ナイト','セイバー','ミラージュ','オーラ','ギフト','チャンス','スマイル',
    'コメット','オーロラ','シャイン','グロウ','ヴェール','カノン','ポエム','ティアラ','クラウン','タイガ','リュウ'];
  c text[] := array['','','','ゼロ','ワン','ツー','ミニ','マックス','プラス','エックス'];
  n text; i int := 0;
begin
  loop
    i := i + 1;
    n := a[1 + floor(random() * array_length(a, 1))::int] || b[1 + floor(random() * array_length(b, 1))::int];
    if i > 15 then n := n || c[1 + floor(random() * array_length(c, 1))::int]; end if;
    if char_length(n) between 3 and 9 and not exists (select 1 from keiba_horses where name = n) then return n; end if;
    if i > 300 then return n || (100 + floor(random() * 900))::int::text; end if;
  end loop;
end $$;

-- 新しい馬をつくる
create or replace function public._kb_new_horse(cls int, age int) returns int
language plpgsql volatile set search_path = public as $$
declare
  nid int; c1 text; c2 text; sx text; bd int;
  colors text[] := array['#C0283C','#1F4E9C','#1D7A4C','#E0A020','#6A2C91','#E86A17','#111111','#FFFFFF',
                         '#E85D9A','#2BA6C9','#8B5A2B','#7A8B99','#F2D16B','#0F5E5A'];
  mu numeric := case cls when 0 then 42 when 1 then 52 when 2 then 59 when 3 then 65 else 73 end;
  sd numeric := case cls when 0 then 7 when 1 then 6 when 2 then 5 when 3 then 5 else 6 end;
  w int := case when cls >= 4 then 4 + floor(random() * 3)::int else cls end;
begin
  sx := case when age <= 2 then (array['牡','牡','牝'])[1 + floor(random() * 3)::int]
             else (array['牡','牡','牡','牝','牝','セ'])[1 + floor(random() * 6)::int] end;
  bd := (array[1200,1400,1600,1600,1800,2000,2000,2200,2400,2800,3200])[1 + floor(random() * 11)::int]
        + floor(_kb_norm() * 100)::int;
  c1 := colors[1 + floor(random() * array_length(colors, 1))::int];
  loop
    c2 := colors[1 + floor(random() * array_length(colors, 1))::int];
    exit when c2 <> c1;
  end loop;
  insert into keiba_horses(name, sex, born, coat, silk1, silk2, silk_pat, ability, style, best_dist, dist_width,
                           turf, heavy, body, class, wins, starts, prize)
  values (_kb_name(), sx, _kb_midx(_now()) - age, floor(random() * 6)::int, c1, c2, floor(random() * 7)::int,
          round(mu + _kb_norm() * sd, 1), (array[0,1,1,1,2,2,2,3])[1 + floor(random() * 8)::int],
          bd, 300 + floor(random() * 500)::int,
          round(random()::numeric, 2), round((random() * 2 - 1)::numeric, 2),
          greatest(400, least(560, (448 + _kb_norm() * 22)::int + case when sx = '牝' then -18 else 0 end)),
          cls, w,
          case when age <= 2 and cls = 0 then 0 else w + floor(random() * (3 + w * 2))::int + case when cls = 0 then 1 else 0 end end,
          case cls when 0 then 0 when 1 then 550 when 2 then 1350 when 3 then 2450 else 3950 + floor(random() * 6000)::int end)
  returning id into nid;
  return nid;
end $$;

-- 出走表をつくって、レースの結果も先に計算しておく（結果は発走まで見せない）
create or replace function public._kb_make_race(d date, no int, vid int, rnum int, posttime timestamptz,
  nm text, grade text, cls int, cond text, surface text, dist int, going text, weather text, tier text,
  handicap boolean, nmin int, nmax int) returns void
language plpgsql volatile set search_path = public as $$
declare
  rid bigint := to_char(d, 'YYYYMMDD')::bigint * 100 + no;
  n int := nmin + floor(random() * (nmax - nmin + 1))::int;
  cur int := _kb_midx(_now());
  v keiba_venues; h keiba_horses;
  ids int[]; perm int[]; sc numeric[]; ord int[]; jl int[]; jk int[]; wk int[];
  rpub numeric[]; rtrue numeric[]; raw numeric[]; kin numeric[]; bdiff int[];
  i int; k int; c int; need int; base int; extra int; age int; n0 int; n1 int; nige int;
  p numeric; beta numeric; t0 numeric; spd numeric; tw numeric; rmax numeric; med numeric; cnd numeric; pe numeric;
  js numeric; sz int; order_ix int[]; tms numeric[]; prev numeric; dt numeric; spl numeric; lens numeric; a numeric;
  x0 numeric; lbl text;
begin
  if exists (select 1 from keiba_races where id = rid) then return; end if;
  select * into v from keiba_venues where id = vid;

  -- 出走する馬をえらぶ
  if cls is not null then
    select array_agg(id) into ids from (
      select hh.id from keiba_horses hh
       where not hh.retired and hh.class = cls
         and (hh.last_day is null or hh.last_day < d - 1)
         and case cond when '2yo_new' then cur - hh.born = 2 and hh.starts = 0
                       when '2yo'     then cur - hh.born = 2 and hh.starts > 0
                       when '3yo'     then cur - hh.born = 3
                       else cur - hh.born >= 3 end
       order by -ln(1 - random()) / exp(_kb_fit(hh, surface, dist) / 3)
       limit n) z;
  else
    select array_agg(id) into ids from (
      select hh.id from keiba_horses hh
       where not hh.retired
         and (hh.last_day is null or hh.last_day < d - 1)
         and case cond when '3yo' then cur - hh.born = 3 and hh.class >= 2 else hh.class = 4 and cur - hh.born >= 3 end
       order by hh.ability * _kb_agef(cur - hh.born) + _kb_fit(hh, surface, dist) + hh.prize / 3000.0 + _kb_norm() * 3 desc
       limit n) z;
  end if;
  need := n - coalesce(array_length(ids, 1), 0);
  for i in 1..need loop
    k := _kb_new_horse(coalesce(cls, case when cond = '3yo' then 3 else 4 end),
                       case when cond in ('2yo_new', '2yo') then 2 when cond = '3yo' then 3 else 3 + floor(random() * 4)::int end);
    if cond = '2yo' then update keiba_horses set starts = 1 where id = k; end if;
    ids := coalesce(ids, '{}') || k;
  end loop;
  update keiba_horses set last_day = d where id = any(ids);

  insert into keiba_races(id, day, no, post, venue, rnum, name, grade, cls, cond, surface, dist, going, weather, tier, handicap)
  values (rid, d, no, posttime, vid, rnum, nm, grade, cls, cond, surface, dist, going, weather, tier, handicap);

  -- 馬番（くじ）と枠（多い頭数のときは外の枠から2頭ずつ）
  select array_agg(x order by random()) into perm from unnest(ids) x;
  if n <= 8 then
    for i in 1..n loop wk[i] := i; end loop;
  else
    base := n / 8; extra := n % 8; i := 1;
    for k in 1..8 loop
      sz := base + case when k > 8 - extra then 1 else 0 end;
      for c in 1..sz loop wk[i] := k; i := i + 1; end loop;
    end loop;
  end if;

  -- ペース（逃げ・先行の馬が多いとハイペース）
  select count(*) filter (where style = 0), count(*) filter (where style = 1) into n0, n1
    from keiba_horses where id = any(perm);
  p := greatest(-1.5, least(1.5, ((n0 + 0.5 * n1) - 0.3125 * n) / (0.12 * n + 0.5)));

  -- 力の見立て（騎手と斤量を決めるため）
  for i in 1..n loop
    select * into h from keiba_horses where id = perm[i];
    sc[i] := h.ability * _kb_agef(cur - h.born) + _kb_fit(h, surface, dist);
  end loop;
  select array_agg(g order by sv desc) into ord from (select g, sc[g] + _kb_norm() * 4 as sv from generate_series(1, n) g) z;
  select array_agg(jid order by sv desc) into jl from (select id as jid, skill + _kb_norm() * 6 as sv from keiba_jockeys) z;
  for k in 1..n loop jk[ord[k]] := jl[k]; end loop;
  select percentile_cont(0.5) within group (order by sx) into med from unnest(sc) sx;
  select count(*) into nige from keiba_horses where id = any(perm) and style = 0;

  for i in 1..n loop
    select * into h from keiba_horses where id = perm[i];
    age := cur - h.born;
    if handicap then
      kin[i] := greatest(50, least(59, 55 + round((sc[i] - med) / 3)));
    else
      kin[i] := case when age <= 2 then 55 when age = 3 and cond = '3yo' then 57 when age = 3 then 55
                     when grade = 'G1' then 58 else 57 end
              - case when h.sex = '牝' then 2 else 0 end;
    end if;
    bdiff[i] := round(_kb_norm() * 5)::int;
    if random() < 0.08 then bdiff[i] := (case when random() < 0.5 then -1 else 1 end) * (10 + floor(random() * 8))::int; end if;
    select skill into js from keiba_jockeys where id = jk[i];
    rpub[i] := sc[i]
             + case going when '稍重' then 0.5 when '重' then 1 when '不良' then 1.5 else 0 end * h.heavy * 2
             + (js - 55) / 8
             - (kin[i] - 55) * 0.8;
    -- 調子（馬体重が大きく増減すると悪くなりやすい）とペース・コースの有利不利
    cnd := _kb_norm() * 1.2 - greatest(abs(bdiff[i]) - 8, 0) * 0.3;
    pe := case h.style
            when 0 then -1.8 * p + v.front + case when nige = 1 then 1.2 else 0 end
            when 1 then -0.9 * p + 0.5 * v.front
            when 2 then  0.8 * p - 0.4 * v.front
            else         1.5 * p - 0.8 * v.front end;
    rtrue[i] := rpub[i] + cnd + pe;
    insert into keiba_entries(race_id, uma, waku, horse_id, jockey, age, kinryo, body, body_diff, r_pub, r_true, lane)
    values (rid, i, wk[i], h.id, jk[i], age, kin[i], greatest(380, h.body + bdiff[i]), bdiff[i],
            round(rpub[i], 3), round(rtrue[i], 3),
            round(((i - 1)::numeric / greatest(n - 1, 1)) * 0.85 + random()::numeric * 0.15, 3));
  end loop;

  -- 着順（本当の力＋運）。運はガンベル分布なので、勝つ確率は人気（オッズ）と同じ形の式になる
  beta := 0.55 * sqrt(dist / 1000.0);
  for i in 1..n loop
    raw[i] := -(rtrue[i] - 50) * 0.1 * dist / 1000.0 - beta * _kb_gumbel();
  end loop;
  select array_agg(g order by raw[g]) into order_ix from generate_series(1, n) g;

  -- タイム（表示用。着差は本物らしい大きさにちぢめる）
  spd := (17.9 - 0.00052 * dist) * case when surface = '芝' then 1 else 0.965 end
         * case when surface = '芝' then (case going when '稍重' then 0.99 when '重' then 0.978 when '不良' then 0.965 else 1 end)
                else (case going when '稍重' then 1.004 when '重' then 1.008 when '不良' then 1.004 else 1 end) end;
  t0 := dist / spd;
  tw := t0 + 0.5 * raw[order_ix[1]];
  spl := 2.4 * tw / dist;                      -- 1馬身あたりの秒
  x0 := 1 - 600.0 / dist;
  prev := null;
  for k in 1..n loop
    i := order_ix[k];
    dt := raw[i] - raw[order_ix[1]];
    tms[i] := tw + 0.3 * dt + 0.04 * dt * dt;
    if prev is null then
      lbl := null;
    else
      lens := (tms[i] - prev) / spl;
      lbl := case when lens < 0.06 then 'ハナ' when lens < 0.15 then 'アタマ' when lens < 0.3 then 'クビ'
                  when lens < 0.6 then '1/2' when lens < 0.85 then '3/4' when lens < 1.1 then '1'
                  when lens < 1.35 then '1 1/4' when lens < 1.6 then '1 1/2' when lens < 1.85 then '1 3/4'
                  when lens < 2.25 then '2' when lens < 2.75 then '2 1/2' when lens < 3.25 then '3'
                  when lens < 3.75 then '3 1/2' when lens < 10.5 then round(lens)::int::text else '大差' end;
    end if;
    prev := tms[i];
    select style into c from keiba_horses where id = perm[i];
    a := (array[0.045, 0.02, -0.012, -0.035])[c + 1]
         + 0.012 * p * case when c <= 1 then 1 else -1 end + _kb_norm() * 0.006;
    update keiba_entries
       set pos = k, time_ms = round(tms[i] * 1000)::int, margin = lbl, shape = round(a, 4),
           last3f = round(tms[i] * (600.0 / dist + a * x0 * (1 - x0)), 1)
     where race_id = rid and uma = i;
  end loop;

  -- 人気（みんなの見立て）からオッズ
  select max(x) into rmax from unnest(rpub) x;
  for i in 1..n loop
    update keiba_entries set w = exp((rpub[i] - rmax) * 0.1 * dist / 1000.0 / beta) where race_id = rid and uma = i;
  end loop;
  update keiba_entries set odds_win = _kb_odds(rid, 'tan', array[uma]), odds_place = _kb_odds(rid, 'fuku', array[uma])
   where race_id = rid;
  update keiba_entries e set ninki = z.rk
    from (select uma, row_number() over (order by odds_win, uma) rk from keiba_entries where race_id = rid) z
   where e.race_id = rid and e.uma = z.uma;
  update keiba_races
     set pace = case when p > 0.6 then 'ハイ' when p < -0.6 then 'スロー' else '平均' end,
         finish_ms = (select max(time_ms) from keiba_entries where race_id = rid)
   where id = rid;
end $$;

-- 1日分の番組をつくる
create or replace function public._kb_make_day(d date) returns void
language plpgsql volatile set search_path = public as $$
declare
  dow int := extract(isodow from d)::int;
  wk int := (extract(day from d)::int - 1) / 7;
  s int; k int; vid int; posttime timestamptz; v keiba_venues; sf text; ds int; cls int; cond text; nm text;
  wth text[]; gt text[]; gd text[]; x numeric; nr keiba_names; knd text; found_nr boolean;
begin
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from keiba_races where day = d) then return; end if;
  for vid in 1..5 loop
    x := random();
    wth[vid] := case when x < 0.5 then '晴' when x < 0.8 then '曇' when x < 0.9 then '小雨' else '雨' end;
    gt[vid] := case wth[vid] when '晴' then case when random() < 0.88 then '良' else '稍重' end
                             when '曇' then case when random() < 0.75 then '良' else '稍重' end
                             when '小雨' then case when random() < 0.6 then '稍重' else '重' end
                             else case when random() < 0.55 then '重' else '不良' end end;
    gd[vid] := case wth[vid] when '晴' then case when random() < 0.85 then '良' else '稍重' end
                             when '曇' then case when random() < 0.7 then '良' else '稍重' end
                             when '小雨' then case when random() < 0.5 then '稍重' else '重' end
                             else case when random() < 0.5 then '重' else '不良' end end;
  end loop;
  for s in 0..3 loop
    vid := s + 1;
    select * into v from keiba_venues where id = vid;
    for k in 1..7 loop
      posttime := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int,
                                   16 + s, 30, 0, 'Asia/Tokyo') + (k - 1) * interval '8 minutes';
      sf := case when random() < 0.55 then '芝' else 'ダ' end;
      ds := case when sf = '芝' then v.turf_d[1 + floor(random() * array_length(v.turf_d, 1))::int]
                 else v.dirt_d[1 + floor(random() * array_length(v.dirt_d, 1))::int] end;
      case k
        when 1 then cls := 0; cond := case when s % 2 = 0 then '2yo_new' else '2yo' end;
        when 2 then cls := 0; cond := '3yo';
        when 3, 4 then cls := 1; cond := '3up';
        when 5, 6 then cls := 2; cond := '3up';
        else cls := 3; cond := '3up';
      end case;
      nm := case cond when '2yo_new' then '2歳新馬' when '2yo' then '2歳未勝利' when '3yo' then '3歳未勝利'
                      else '3歳以上' || cls || '勝クラス' end;
      perform _kb_make_race(d, s * 7 + k, vid, k, posttime, nm, null, cls, cond, sf, ds,
                            case when sf = '芝' then gt[vid] else gd[vid] end, wth[vid], 'normal', false, 8, 12);
    end loop;
  end loop;
  -- メインレース（20:30）
  knd := case dow when 7 then 'g1' when 6 then 'sat' else 'wd' end;
  select * into nr from keiba_names where kind = knd and idx = case when knd = 'wd' then dow else wk end;
  found_nr := found;
  if not found_nr then
    nr.name := 'オープン特別'; nr.grade := 'OP'; nr.surface := '芝'; nr.dist := 1800; nr.cond := '3up'; nr.handicap := false;
  end if;
  posttime := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 20, 30, 0, 'Asia/Tokyo');
  perform _kb_make_race(d, 29, 5, 11, posttime, nr.name, nr.grade, null, nr.cond, nr.surface, nr.dist,
                        case when nr.surface = '芝' then gt[5] else gd[5] end, wth[5],
                        case when nr.grade = 'G1' then 'g1' else 'graded' end, nr.handicap,
                        case nr.grade when 'G1' then 16 when 'G2' then 12 when 'G3' then 12 else 10 end,
                        case nr.grade when 'G1' then 18 when 'G2' then 16 when 'G3' then 16 else 14 end);
end $$;

-- 順番つきの確率（PL式）：a→b→c…の順に入る確率
create or replace function public._kb_seq(w numeric[], tw numeric, s int[]) returns numeric
language plpgsql immutable as $$
declare p numeric := 1; rest numeric := tw; x int;
begin
  foreach x in array s loop
    if rest <= 0 then return 0; end if;
    p := p * w[x] / rest; rest := rest - w[x];
  end loop;
  return p;
end $$;

-- 馬券が当たる確率（みんなの見立てで）
create or replace function public._kb_prob(rid bigint, kind text, sel int[]) returns numeric
language plpgsql stable set search_path = public as $$
declare w numeric[]; wk int[]; n int; tw numeric := 0; p numeric := 0; i int; j int; x int; y int; a int; b int; c int;
begin
  select array_agg(e.w order by e.uma), array_agg(e.waku order by e.uma) into w, wk from keiba_entries e where e.race_id = rid;
  n := array_length(w, 1);
  for i in 1..n loop tw := tw + w[i]; end loop;
  a := sel[1]; b := sel[2]; c := sel[3];
  case kind
    when 'tan' then p := w[a] / tw;
    when 'fuku' then
      p := w[a] / tw;
      for x in 1..n loop
        continue when x = a;
        p := p + _kb_seq(w, tw, array[x, a]);
        for y in 1..n loop
          continue when y = a or y = x;
          p := p + _kb_seq(w, tw, array[x, y, a]);
        end loop;
      end loop;
    when 'umatan' then p := _kb_seq(w, tw, array[a, b]);
    when 'umaren' then p := _kb_seq(w, tw, array[a, b]) + _kb_seq(w, tw, array[b, a]);
    when 'trifecta' then p := _kb_seq(w, tw, array[a, b, c]);
    when 'trio' then
      p := _kb_seq(w, tw, array[a, b, c]) + _kb_seq(w, tw, array[a, c, b]) + _kb_seq(w, tw, array[b, a, c])
         + _kb_seq(w, tw, array[b, c, a]) + _kb_seq(w, tw, array[c, a, b]) + _kb_seq(w, tw, array[c, b, a]);
    when 'wide' then
      for x in 1..n loop
        continue when x = a or x = b;
        p := p + _kb_prob_trio(w, tw, a, b, x);
      end loop;
    when 'waku' then
      for i in 1..n loop
        for j in i + 1..n loop
          if (wk[i] = a and wk[j] = b) or (wk[i] = b and wk[j] = a) then
            p := p + _kb_seq(w, tw, array[i, j]) + _kb_seq(w, tw, array[j, i]);
          end if;
        end loop;
      end loop;
  end case;
  return p;
end $$;

create or replace function public._kb_prob_trio(w numeric[], tw numeric, a int, b int, c int) returns numeric
language sql immutable as $$
  select public._kb_seq(w, tw, array[a, b, c]) + public._kb_seq(w, tw, array[a, c, b]) + public._kb_seq(w, tw, array[b, a, c])
       + public._kb_seq(w, tw, array[b, c, a]) + public._kb_seq(w, tw, array[c, a, b]) + public._kb_seq(w, tw, array[c, b, a])
$$;

-- 払戻率
create or replace function public._kb_rate(tier text, kind text) returns numeric
language sql immutable as $$
  select (case kind when 'tan' then 0.80 when 'fuku' then 0.80 when 'waku' then 0.775 when 'umaren' then 0.775
                    when 'wide' then 0.775 when 'umatan' then 0.75 when 'trio' then 0.75 else 0.725 end)
       + case tier when 'normal' then -0.05 when 'g1' then 0.05 else 0 end
$$;

-- オッズ（0.1倍きざみで切り捨て。最低1.0倍）
create or replace function public._kb_odds(rid bigint, kind text, sel int[]) returns numeric
language plpgsql stable set search_path = public as $$
declare p numeric; tr text;
begin
  select tier into tr from keiba_races where id = rid;
  p := _kb_prob(rid, kind, sel);
  if p <= 0 then return 99999.9; end if;
  return round(least(99999.9, greatest(1.0, floor(_kb_rate(tr, kind) / p * 10) / 10)), 1);
end $$;

-- 馬券の選び方を確かめて、決まった形にそろえる
create or replace function public._kb_check_sel(rid bigint, kind text, sel int[]) returns int[]
language plpgsql stable set search_path = public as $$
declare n int; need int; s int[]; x int; wk int[];
begin
  select count(*), array_agg(waku order by uma) into n, wk from keiba_entries where race_id = rid;
  need := case kind when 'tan' then 1 when 'fuku' then 1 when 'waku' then 2 when 'umaren' then 2 when 'wide' then 2
                    when 'umatan' then 2 when 'trio' then 3 when 'trifecta' then 3 end;
  if need is null then raise exception '知らない馬券です'; end if;
  if sel is null or coalesce(array_length(sel, 1), 0) <> need then raise exception '馬を%頭えらんでください', need; end if;
  if kind = 'waku' then
    if n < 9 then raise exception '8頭以下のレースでは枠連は買えません'; end if;
    foreach x in array sel loop
      if x < 1 or x > 8 then raise exception '枠は1〜8です'; end if;
    end loop;
    s := array[least(sel[1], sel[2]), greatest(sel[1], sel[2])];
    if s[1] = s[2] and (select count(*) from unnest(wk) z where z = s[1]) < 2 then
      raise exception 'この枠には1頭しかいません';
    end if;
    return s;
  end if;
  foreach x in array sel loop
    if x < 1 or x > n then raise exception '馬番は1〜%です', n; end if;
  end loop;
  if (select count(distinct z) from unnest(sel) z) <> need then raise exception '同じ馬は2回えらべません'; end if;
  if kind in ('umaren', 'wide', 'trio') then
    select array_agg(z order by z) into s from unnest(sel) z;
    return s;
  end if;
  return sel;
end $$;

-- 当たったか
create or replace function public._kb_hit(kind text, sel int[], res int[], wk int[]) returns boolean
language sql immutable as $$
  select case kind
    when 'tan'      then sel[1] = res[1]
    when 'fuku'     then sel[1] = any(res[1:3])
    when 'waku'     then least(wk[res[1]], wk[res[2]]) = sel[1] and greatest(wk[res[1]], wk[res[2]]) = sel[2]
    when 'umaren'   then least(res[1], res[2]) = sel[1] and greatest(res[1], res[2]) = sel[2]
    when 'wide'     then sel[1] = any(res[1:3]) and sel[2] = any(res[1:3])
    when 'umatan'   then sel[1] = res[1] and sel[2] = res[2]
    when 'trio'     then sel @> res[1:3] and res[1:3] @> sel
    when 'trifecta' then sel = res[1:3]
    else false end
$$;

-- レースを確定して払い戻す。馬の成績も更新
create or replace function public._kb_settle(rid bigint) returns void
language plpgsql volatile set search_path = public as $$
declare
  r keiba_races; e record; t keiba_tickets; res int[]; wk int[]; hit boolean; pay bigint; prize1 numeric;
  sh numeric[] := array[1, 0.4, 0.25, 0.15, 0.1];
begin
  select * into r from keiba_races where id = rid for update;
  if not found or r.settled then return; end if;
  select array_agg(uma order by pos) into res from keiba_entries where race_id = rid;
  select array_agg(waku order by uma) into wk from keiba_entries where race_id = rid;
  prize1 := case coalesce(r.grade, '')
              when 'G1' then case when r.name like '%ダービー%' or r.name like '%グランプリ%' then 30000 else 15000 end
              when 'G2' then 5800 when 'G3' then 4100 when 'L' then 2400 when 'OP' then 2200
              else (array[550, 800, 1100, 1500])[coalesce(r.cls, 0) + 1] end;
  for e in select * from keiba_entries where race_id = rid loop
    update keiba_horses
       set starts = starts + 1,
           wins   = wins + case when e.pos = 1 then 1 else 0 end,
           class  = case when e.pos = 1 then least(class + 1, 4) else class end,
           graded = graded + case when e.pos = 1 and r.grade in ('G1','G2','G3') then 1 else 0 end,
           prize  = prize + case when e.pos <= 5 then floor(prize1 * sh[e.pos]) else 0 end,
           body   = e.body
     where id = e.horse_id;
  end loop;
  for t in select * from keiba_tickets where race_id = rid and payout is null order by id for update loop
    hit := _kb_hit(t.kind, t.sel, res, wk);
    pay := case when hit then floor(t.amount * t.odds) else 0 end;
    update keiba_tickets set payout = pay where id = t.id;
    perform _give(t.user_id, pay);
    perform _log(t.user_id, 'race', t.amount, pay, jsonb_build_object('race', rid, 'kind', t.kind, 'sel', t.sel));
  end loop;
  update keiba_races set settled = true where id = rid;
end $$;

-- 月が変わったら：8歳と、4歳になっても勝てなかった馬は引退。2歳の新馬が入ってくる
create or replace function public._kb_month(cur int) returns void
language plpgsql volatile set search_path = public as $$
declare i int;
begin
  update keiba_horses set retired = true
   where not retired and (cur - born >= 8 or (class = 0 and cur - born >= 4));
  for i in 1..150 loop perform _kb_new_horse(0, 2); end loop;
  update app_settings set value = cur::text where key = 'keiba_month';
end $$;

-- はじめて動かすとき：馬をそろえて、過去6日分のレースを走らせて成績をつくる
create or replace function public._kb_seed() returns void
language plpgsql volatile set search_path = public as $$
declare d date; i int; r record; today date := _kb_jday(_now());
begin
  perform pg_advisory_xact_lock(4243);
  if exists (select 1 from keiba_horses limit 1) then return; end if;
  for i in 1..150 loop perform _kb_new_horse(0, 2); end loop;
  for i in 1..130 loop perform _kb_new_horse(0, 3); end loop;
  for i in 1..230 loop perform _kb_new_horse(1, 3 + floor(random() * 4)::int); end loop;
  for i in 1..200 loop perform _kb_new_horse(2, 3 + floor(random() * 5)::int); end loop;
  for i in 1..120 loop perform _kb_new_horse(3, 4 + floor(random() * 4)::int); end loop;
  for i in 1..110 loop perform _kb_new_horse(4, 3 + floor(random() * 5)::int); end loop;
  insert into app_settings values ('keiba_month', _kb_midx(_now())::text)
  on conflict (key) do update set value = excluded.value;
  for d in select g::date from generate_series(today - 6, today - 1, interval '1 day') g loop
    perform _kb_make_day(d);
    for r in select id from keiba_races where day = d order by id loop
      perform _kb_settle(r.id);
    end loop;
  end loop;
end $$;

-- 競馬の時計：終わったレースの確定、月の変わり目、今日の番組づくり
create or replace function public._kb_tick() returns void
language plpgsql volatile set search_path = public as $$
declare r record; cur int := _kb_midx(_now()); last int; today date := _kb_jday(_now());
begin
  if not exists (select 1 from keiba_horses limit 1) then perform _kb_seed(); end if;
  for r in select id from keiba_races
            where not settled and post + make_interval(secs => (coalesce(finish_ms, 0) + 20000) / 1000.0) <= _now()
            order by id loop
    perform _kb_settle(r.id);
  end loop;
  select value::int into last from app_settings where key = 'keiba_month';
  if last is null then
    insert into app_settings values ('keiba_month', cur::text) on conflict (key) do nothing;
  elsif last < cur then
    perform _kb_month(cur);
  end if;
  if not exists (select 1 from keiba_races where day = today) then perform _kb_make_day(today); end if;
end $$;

-- 発売の状態
create or replace function public._kb_status(r public.keiba_races) returns text
language sql stable as $$
  select case when r.settled then 'final'
              when public._now() < r.post - interval '60 seconds' then 'sale'
              when public._now() < r.post then 'closed'
              when public._now() < r.post + make_interval(secs => (coalesce(r.finish_ms, 0) + 1500) / 1000.0) then 'running'
              else 'judging' end
$$;

-- きょうの開催
create or replace function public.keiba_day() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); today date;
begin
  perform _kb_tick();
  today := _kb_jday(_now());
  return jsonb_build_object(
    'now_ms', _kb_ms(_now()),
    'day', today,
    'races', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'no', r.no, 'rnum', r.rnum, 'post_ms', _kb_ms(r.post), 'venue', v.name,
        'name', r.name, 'grade', r.grade, 'surface', r.surface, 'dist', r.dist, 'going', r.going,
        'weather', r.weather, 'status', _kb_status(r),
        'n', (select count(*) from keiba_entries e where e.race_id = r.id),
        'winner', case when r.settled then (select jsonb_build_object('uma', e.uma, 'name', h.name, 'ninki', e.ninki)
                                              from keiba_entries e join keiba_horses h on h.id = e.horse_id
                                             where e.race_id = r.id and e.pos = 1) end,
        'mine', (select count(*) from keiba_tickets t where t.race_id = r.id and t.user_id = u)
      ) order by r.post), '[]'::jsonb)
      from keiba_races r join keiba_venues v on v.id = r.venue where r.day = today),
    'balance', _bal(u));
end $$;

-- 1レース分（出走表・オッズ・自分の馬券、発走後は走り、確定後は払戻）
create or replace function public.keiba_race(p_race bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _me(); r keiba_races; v keiba_venues; st text; started boolean; ent jsonb; pays jsonb := '[]'::jsonb;
  mine jsonb; res int[]; wk int[]; n int; s int[];
begin
  perform _kb_tick();
  select * into r from keiba_races where id = p_race;
  if not found then raise exception 'レースが見つかりません'; end if;
  select * into v from keiba_venues where id = r.venue;
  st := _kb_status(r);
  started := r.post <= _now();

  select jsonb_agg(jsonb_build_object(
      'uma', e.uma, 'waku', e.waku, 'horse_id', h.id, 'name', h.name, 'sex', h.sex, 'age', e.age,
      'kinryo', e.kinryo, 'jockey', j.name, 'body', e.body, 'body_diff', e.body_diff, 'style', h.style,
      'coat', h.coat, 'silk1', h.silk1, 'silk2', h.silk2, 'silk_pat', h.silk_pat,
      'odds_win', e.odds_win, 'odds_place', e.odds_place, 'ninki', e.ninki,
      'record', format('%s戦%s勝', h.starts, h.wins), 'graded', h.graded,
      'last5', (select coalesce(jsonb_agg(jsonb_build_object('pos', x.pos, 'n', x.n, 'grade', x.grade,
                         'dist', x.dist, 'surface', x.surface, 'venue', x.venue) order by x.race_id desc), '[]'::jsonb)
                  from (select e2.race_id, e2.pos, r2.grade, r2.dist, r2.surface, v2.name venue,
                               (select count(*) from keiba_entries e3 where e3.race_id = e2.race_id) n
                          from keiba_entries e2 join keiba_races r2 on r2.id = e2.race_id
                          join keiba_venues v2 on v2.id = r2.venue
                         where e2.horse_id = h.id and e2.race_id < r.id and r2.settled
                         order by e2.race_id desc limit 5) x),
      'run', case when started then jsonb_build_object('pos', e.pos, 'time_ms', e.time_ms, 'margin', e.margin,
                                                       'last3f', e.last3f, 'shape', e.shape, 'lane', e.lane) end
    ) order by e.uma) into ent
    from keiba_entries e join keiba_horses h on h.id = e.horse_id join keiba_jockeys j on j.id = e.jockey
   where e.race_id = r.id;

  if r.settled then
    select array_agg(uma order by pos), count(*) into res, n from keiba_entries where race_id = r.id;
    select array_agg(waku order by uma) into wk from keiba_entries where race_id = r.id;
    pays := jsonb_build_array(
      jsonb_build_object('kind', 'tan', 'sel', array[res[1]], 'odds', _kb_odds(r.id, 'tan', array[res[1]])),
      jsonb_build_object('kind', 'fuku', 'sel', array[res[1]], 'odds', _kb_odds(r.id, 'fuku', array[res[1]])),
      jsonb_build_object('kind', 'fuku', 'sel', array[res[2]], 'odds', _kb_odds(r.id, 'fuku', array[res[2]])),
      jsonb_build_object('kind', 'fuku', 'sel', array[res[3]], 'odds', _kb_odds(r.id, 'fuku', array[res[3]])));
    if n >= 9 then
      s := array[least(wk[res[1]], wk[res[2]]), greatest(wk[res[1]], wk[res[2]])];
      pays := pays || jsonb_build_object('kind', 'waku', 'sel', s, 'odds', _kb_odds(r.id, 'waku', s));
    end if;
    s := array[least(res[1], res[2]), greatest(res[1], res[2])];
    pays := pays || jsonb_build_object('kind', 'umaren', 'sel', s, 'odds', _kb_odds(r.id, 'umaren', s));
    foreach s slice 1 in array array[[least(res[1], res[2]), greatest(res[1], res[2])],
                                     [least(res[1], res[3]), greatest(res[1], res[3])],
                                     [least(res[2], res[3]), greatest(res[2], res[3])]] loop
      pays := pays || jsonb_build_object('kind', 'wide', 'sel', s, 'odds', _kb_odds(r.id, 'wide', s));
    end loop;
    pays := pays || jsonb_build_object('kind', 'umatan', 'sel', array[res[1], res[2]], 'odds', _kb_odds(r.id, 'umatan', array[res[1], res[2]]));
    select array_agg(z order by z) into s from unnest(res[1:3]) z;
    pays := pays || jsonb_build_object('kind', 'trio', 'sel', s, 'odds', _kb_odds(r.id, 'trio', s));
    pays := pays || jsonb_build_object('kind', 'trifecta', 'sel', res[1:3], 'odds', _kb_odds(r.id, 'trifecta', res[1:3]));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('kind', t.kind, 'sel', t.sel, 'amount', t.amount, 'odds', t.odds,
                                               'payout', t.payout) order by t.id), '[]'::jsonb) into mine
    from keiba_tickets t where t.race_id = r.id and t.user_id = u;

  return jsonb_build_object(
    'now_ms', _kb_ms(_now()),
    'race', jsonb_build_object(
      'id', r.id, 'no', r.no, 'rnum', r.rnum, 'day', r.day, 'post_ms', _kb_ms(r.post), 'status', st,
      'name', r.name, 'grade', r.grade, 'cls', r.cls, 'cond', r.cond, 'surface', r.surface, 'dist', r.dist,
      'going', r.going, 'weather', r.weather, 'tier', r.tier, 'handicap', r.handicap,
      'pace', case when started then r.pace end, 'finish_ms', case when started then r.finish_ms end,
      'venue', jsonb_build_object('name', v.name, 'turn', v.turn, 'straight', v.straight, 'slope', v.slope, 'circuit', v.circuit),
      'rates', jsonb_build_object('tan', _kb_rate(r.tier, 'tan'), 'umaren', _kb_rate(r.tier, 'umaren'),
                                  'trio', _kb_rate(r.tier, 'trio'), 'trifecta', _kb_rate(r.tier, 'trifecta'))),
    'entries', coalesce(ent, '[]'::jsonb),
    'payouts', pays,
    'mine', mine,
    'balance', _bal(u));
end $$;

-- 買う前にオッズを見る
create or replace function public.keiba_odds(p_race bigint, p_kind text, p_sel int[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); s int[];
begin
  s := _kb_check_sel(p_race, p_kind, p_sel);
  return jsonb_build_object('sel', s, 'odds', _kb_odds(p_race, p_kind, s));
end $$;

-- 馬券を買う（オッズは買った時点で決まる）
create or replace function public.keiba_bet(p_race bigint, p_kind text, p_sel int[], p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r keiba_races; s int[]; od numeric;
begin
  perform _kb_tick();
  select * into r from keiba_races where id = p_race;
  if not found then raise exception 'レースが見つかりません'; end if;
  if _now() >= r.post - interval '60 seconds' then raise exception 'このレースの発売は締め切りました'; end if;
  s := _kb_check_sel(p_race, p_kind, p_sel);
  od := _kb_odds(p_race, p_kind, s);
  perform _take(u, p_amount);
  insert into keiba_tickets(race_id, user_id, kind, sel, amount, odds) values (p_race, u, p_kind, s, p_amount, od);
  return jsonb_build_object('odds', od, 'sel', s,
    'mine', (select coalesce(jsonb_agg(jsonb_build_object('kind', t.kind, 'sel', t.sel, 'amount', t.amount,
                     'odds', t.odds, 'payout', t.payout) order by t.id), '[]'::jsonb)
               from keiba_tickets t where t.race_id = p_race and t.user_id = u),
    'balance', _bal(u));
end $$;

-- 馬のくわしい成績
create or replace function public.keiba_horse(p_horse int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses;
begin
  select * into h from keiba_horses where id = p_horse;
  if not found then raise exception '馬が見つかりません'; end if;
  return jsonb_build_object(
    'name', h.name, 'sex', h.sex, 'age', _kb_midx(_now()) - h.born, 'coat', h.coat, 'style', h.style,
    'silk1', h.silk1, 'silk2', h.silk2, 'silk_pat', h.silk_pat, 'body', h.body,
    'class', h.class, 'starts', h.starts, 'wins', h.wins, 'prize', h.prize, 'graded', h.graded, 'retired', h.retired,
    'runs', (select coalesce(jsonb_agg(jsonb_build_object(
                 'day', r.day, 'venue', v.name, 'name', r.name, 'grade', r.grade, 'surface', r.surface, 'dist', r.dist,
                 'going', r.going, 'n', (select count(*) from keiba_entries e3 where e3.race_id = r.id),
                 'uma', e.uma, 'ninki', e.ninki, 'pos', e.pos, 'time_ms', e.time_ms, 'margin', e.margin,
                 'last3f', e.last3f, 'jockey', j.name, 'kinryo', e.kinryo, 'body', e.body, 'body_diff', e.body_diff
               ) order by r.id desc), '[]'::jsonb)
               from keiba_entries e join keiba_races r on r.id = e.race_id join keiba_venues v on v.id = r.venue
               join keiba_jockeys j on j.id = e.jockey
              where e.horse_id = h.id and r.settled));
end $$;

-- ---------------------------------------------------------------------
-- 実行権限：内部用（_ではじまる）は画面から呼べないようにする
-- ---------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname in (
            '_me','_rint','_take','_give','_bal','_log','_card','_cards','_slot_sym',
            '_hilo_json','_bj_total','_bj_json','_bj_finish',
            'ensure_profile','my_profile','set_nickname','leaderboard','my_history','slot_spin',
            'roulette_spin','hilo_state','hilo_start','hilo_guess','hilo_cashout','bj_state',
            'bj_start','bj_hit','bj_stand','bj_double',
            '_now','_month_of','_month_start','_next_month','_prev_month','_jday','_dlabel','_fmt',
            '_tax','_income','_notice','_debt','_pay_tax','_process_month','_tax_tick','_tax_badge','_assets',
            'tax_state','tax_file','tax_pay',
            '_kb_norm','_kb_gumbel','_kb_midx','_kb_jday','_kb_ms','_kb_agef','_kb_fit','_kb_name','_kb_new_horse',
            '_kb_make_race','_kb_make_day','_kb_seq','_kb_prob','_kb_prob_trio','_kb_rate','_kb_odds','_kb_check_sel',
            '_kb_hit','_kb_settle','_kb_month','_kb_seed','_kb_tick','_kb_status',
            'keiba_day','keiba_race','keiba_odds','keiba_bet','keiba_horse') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if left(f.proname, 1) = '_' then
      execute format('revoke all on function %s from authenticated', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
