-- =====================================================================
--  AiliNaX カジノ  サーバー側（Supabase の SQL Editor に貼って Run）
--  ・AiliNaX は架空通貨です。現金・物・他の通貨との交換はできません（ゲーム内アイテムとの取引は可。RMTは不可）。
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
-- 送金（あとから足した列）
alter table public.profiles add column if not exists account_no text;
create unique index if not exists profiles_account_no_idx on public.profiles(account_no);
-- 利用停止（役所の判決）・メール認証（オレンジのチェック用）
alter table public.profiles add column if not exists banned_until timestamptz;
alter table public.profiles add column if not exists mail_verified_at timestamptz;
alter table public.treasury add column if not exists fee_total bigint not null default 0;

-- 企業・銀行 ---------------------------------------------------------
create table if not exists public.companies (
  id          serial primary key,
  cid         text not null unique,                 -- 5けたのID（ユーザーと同じ番号のしくみ）
  owner       uuid not null references public.profiles(id) on delete cascade,
  name        text not null,
  kind        text not null check (kind in ('一般','銀行')),
  description text not null default '',
  status      text not null default 'pending',      -- pending（審査中）/ active / rejected
  balance     bigint not null default 0 check (balance >= 0),
  rate        numeric not null default 0,           -- 銀行の預金金利（1日あたり%）
  fee_paid    bigint not null default 0,
  reason      text,
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);
-- 会社の形（株式会社・有限会社・合同会社）。name には「株式会社〇〇」のように形もふくめた名前を入れる
alter table public.companies add column if not exists form text not null default '株式会社';
-- 会社のID：「会社番号3けた-代表（社長）のID5けた」（例 101-76705）。取引は最初の3けただけでもできる
create or replace function public._cfull(c companies) returns text
language plpgsql stable set search_path = public as $$
begin
  return c.cid || '-' || coalesce((select account_no from profiles where id = c.owner), '');
end $$;
-- 入力されたIDを会社番号にそろえる（「101-76705」→「101」。後ろの5けたが今の社長と合わなければエラー）
create or replace function public._cid_norm(p text) returns text
language plpgsql stable set search_path = public as $$
declare k text := btrim(coalesce(p, '')); pre text; suf text; o text;
begin
  if k ~ '^\d{3,4}-\d{5,6}$' then
    pre := split_part(k, '-', 1); suf := split_part(k, '-', 2);
    select p2.account_no into o from companies c join profiles p2 on p2.id = c.owner where c.cid = pre;
    if o is not null and o <> suf then
      raise exception 'IDの後ろの5けた（代表）が、いまの社長と合いません。最初の3けた（%）だけでも取引できます', pre;
    end if;
    return pre;
  end if;
  return k;
end $$;
-- 新しい会社番号（100から順番。使い切ったら4けた）
create or replace function public._new_ccode() returns text
language plpgsql set search_path = public as $$
declare n int;
begin
  select greatest(coalesce(max(cid::int), 99) + 1, 100) into n from companies where cid ~ '^\d{3,4}$';
  if n > 9999 then raise exception '会社番号がいっぱいです'; end if;
  return n::text;
end $$;
-- 業種：一般・銀行・証券
alter table public.companies drop constraint if exists companies_kind_check;
alter table public.companies add constraint companies_kind_check check (kind in ('一般', '銀行', '証券'));
-- 状態：pending（審査中）/ active / suspended（休業）/ closed（廃業）/ bankrupt（倒産）/ rejected
alter table public.companies add column if not exists closed_at timestamptz;
alter table public.companies add column if not exists court_lock boolean not null default false;   -- 役所の命令で休業中（自分では再開できない）
drop index if exists public.companies_name_idx;
create unique index if not exists companies_name_live_idx on public.companies(lower(name)) where status not in ('rejected', 'closed', 'bankrupt');
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'companies_form_chk') then
    alter table public.companies add constraint companies_form_chk check (form in ('株式会社', '有限会社', '合同会社'));
  end if;
end $$;
-- 国営（公式マークつき。株式はない）
alter table public.companies drop constraint if exists companies_form_chk;
alter table public.companies add constraint companies_form_chk check (form in ('株式会社', '有限会社', '合同会社', '国営'));
alter table public.companies add column if not exists official boolean not null default false;
-- 銀行の設定（銀行が決める）
--   口座開設：off（受け付けない）/ auto（すぐ）/ approve（銀行の許可制）・オレンジのチェックが必要か
--   借入（借りるボタン）：受け付けるか・この銀行の口座が必要か・オレンジのチェックが必要か
alter table public.companies add column if not exists acct_mode text not null default 'approve';
alter table public.companies add column if not exists acct_need_check boolean not null default false;
alter table public.companies add column if not exists loan_on boolean not null default true;
alter table public.companies add column if not exists loan_need_acct boolean not null default false;
alter table public.companies add column if not exists loan_need_check boolean not null default false;
create table if not exists public.corp_items (
  id          bigserial primary key,
  company_id  int not null references public.companies(id) on delete cascade,
  name        text not null,
  price       bigint not null check (price > 0),
  description text not null default '',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create table if not exists public.corp_orders (
  id          bigserial primary key,
  item_id     bigint references public.corp_items(id) on delete set null,
  company_id  int not null references public.companies(id) on delete cascade,
  buyer       uuid not null references public.profiles(id) on delete cascade,
  item_name   text not null,
  price       bigint not null,
  fee         bigint not null,
  note        text,
  status      text not null default 'paid',         -- paid（支払いずみ）/ done（渡しずみ）/ refunded（廃業・倒産で返金）
  created_at  timestamptz not null default now(),
  done_at     timestamptz
);
create index if not exists corp_orders_company_idx on public.corp_orders(company_id, id desc);
create index if not exists corp_orders_buyer_idx on public.corp_orders(buyer, id desc);
create table if not exists public.corp_pins (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  company_id int not null references public.companies(id) on delete cascade,
  primary key (user_id, company_id)
);
create table if not exists public.corp_ledger (           -- 会社のお金の出入り
  id         bigserial primary key,
  company_id int not null references public.companies(id) on delete cascade,
  kind       text not null,
  amount     bigint not null,                            -- ＋入る −出る
  memo       text,
  balance_after bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists corp_ledger_idx on public.corp_ledger(company_id, id desc);
create table if not exists public.bank_accounts (
  company_id     int not null references public.companies(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  balance        bigint not null default 0 check (balance >= 0),
  interest_day   date not null,
  interest_total bigint not null default 0,
  unpaid         numeric not null default 0,
  primary key (company_id, user_id)
);
alter table public.bank_accounts add column if not exists status text not null default 'active';   -- pending（申込中）/ active
alter table public.companies     enable row level security;
alter table public.corp_items    enable row level security;
alter table public.corp_orders   enable row level security;
alter table public.corp_pins     enable row level security;
alter table public.corp_ledger   enable row level security;
alter table public.bank_accounts enable row level security;
revoke all on public.companies, public.corp_items, public.corp_orders, public.corp_pins,
              public.corp_ledger, public.bank_accounts from anon, authenticated;
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
declare u uuid := auth.uid(); bu timestamptz;
begin
  if u is null then raise exception 'ログインしてください'; end if;
  select banned_until into bu from profiles where id = u;
  if bu is not null and bu > _now() then
    raise exception '利用停止中です（%まで）。役所の判決によるものです', to_char(bu at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI');
  end if;
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
  -- 役所の判決で払いきれていない賠償金があれば、入ってきた分から取り立てる
  if amt > 0 and exists (select 1 from court_cases where defendant_user = u and comp_unpaid > 0) then
    perform _court_collect_user(u, amt);
    b := _bal(u);
  end if;
  -- 返す期限を過ぎた借入があれば、入ってきた分から銀行が取り立てる
  if amt > 0 and exists (select 1 from loans where user_id = u and status = 'active' and due_at < _now()) then
    perform _loan_collect(u, amt);
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
  update profiles set account_no = _new_acct() where id = u and account_no is null;
  perform _mail_seen(u);
  -- 締めの日を過ぎていたら、税の締め（調査・差し押さえ・給付金）をここで行う
  -- 万一失敗してもログインは止めない
  begin
    perform _tax_tick();
  exception when others then
    raise warning 'tax tick failed: %', sqlerrm;
  end;
  return (select jsonb_build_object('nickname', nickname, 'balance', balance, 'tax', _tax_badge(u), 'account_no', account_no,
            'is_admin', _is_admin(u), 'role', _role(u), 'badge', _badge(u))
            from profiles where id = u);
end $$;

drop function if exists public.my_profile();
create or replace function public.my_profile() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return (select jsonb_build_object('nickname', nickname, 'balance', balance, 'account_no', account_no,
            'send_ok', _now() >= created_at + interval '7 days', 'send_from', _dlabel(created_at + interval '7 days'),
            'is_admin', _is_admin(id), 'role', _role(id), 'badge', _badge(id),
            'check', jsonb_build_object('days', _now() >= created_at + interval '7 days', 'days_from', _dlabel(created_at + interval '7 days'),
                       'debt', _debt(id), 'mail', mail_verified_at is not null and mail_verified_at >= _now() - interval '183 days',
                       'mail_at', case when mail_verified_at is null then null else _dlabel(mail_verified_at) end,
                       'mail_until', case when mail_verified_at is null then null else _dlabel(mail_verified_at + interval '183 days') end))
            from profiles where id = _me());
end $$;

create or replace function public.set_nickname(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name, ''));
begin
  if char_length(n) < 1 or char_length(n) > 12 then raise exception 'ニックネームは1〜12文字です'; end if;
  update profiles set nickname = n where id = _me();
  return my_profile();
end $$;

-- 所持金は非公開なので、お金持ちランキングは出さない（昔の画面から呼ばれても空を返す）
create or replace function public.leaderboard() returns jsonb
language sql security definer set search_path = public as $$ select '[]'::jsonb $$;

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
   where user_id = u and game in ('slot','roulette','hilo','blackjack','race','work','interest','salary','dividend','liquidation','game_bet','pub_sale')
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

-- 役割：admin（管理者）/ sub（副管理者）/ null
--   管理者は app_settings 'admins'（ユーザーのuuid）、副管理者は 'subadmins'（ユーザーのID。カンマ区切り）
create or replace function public._role(u uuid) returns text
language plpgsql stable set search_path = public as $$
begin
  if u is null then return null; end if;
  if exists (select 1 from app_settings where key = 'admins' and u::text = any(string_to_array(value, ','))) then return 'admin'; end if;
  if exists (select 1 from app_settings s join profiles p on p.id = u
              where s.key = 'subadmins' and p.account_no = any(string_to_array(replace(s.value, ' ', ''), ','))) then return 'sub'; end if;
  return null;
end $$;
create or replace function public._is_staff(u uuid) returns boolean
language plpgsql stable set search_path = public as $$ begin return _role(u) is not null; end $$;

-- 名前の横のしるし：role（管理者タグ）と ok（オレンジのチェック）
--   チェック：税金の滞納がない（前に滞納していても、いま払い終わっていればOK）・登録から7日・半年以内にメールで認証
create or replace function public._badge(u uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where id = u;
  if not found then return null; end if;
  return jsonb_build_object('role', _role(u),
    'ok', _debt(u) = 0 and _now() >= p.created_at + interval '7 days'
          and p.mail_verified_at is not null and p.mail_verified_at >= _now() - interval '183 days');
end $$;

-- ログインのしかたを見て、メールで認証した時刻を覚える（メールのリンク・登録の確認など）
create or replace function public._mail_seen(u uuid) returns void
language plpgsql set search_path = public as $$
declare j jsonb; e jsonb; t timestamptz;
begin
  begin
    j := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then j := null;
  end;
  if j is null or jsonb_typeof(j->'amr') is distinct from 'array' then return; end if;
  for e in select * from jsonb_array_elements(j->'amr') loop
    if e->>'method' in ('otp', 'magiclink', 'email/signup', 'email_change', 'recovery', 'invite') and (e->>'timestamp') ~ '^\d+$' then
      t := to_timestamp((e->>'timestamp')::bigint);
      update profiles set mail_verified_at = t where id = u and (mail_verified_at is null or mail_verified_at < t);
    end if;
  end loop;
end $$;

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
       + coalesce((select sum(balance) from bank_accounts where user_id = u), 0)
       + coalesce((select sum(balance) from companies where owner = u and status in ('active', 'suspended')), 0)
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
  select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'badge', _badge(p.id)) order by t.tax_paid desc), '[]'::jsonb) into top
    from (select * from tax_returns where month = topm and tax_paid > 0 order by tax_paid desc limit 10) t
    join profiles p on p.id = t.user_id;

  select * into tr from treasury where id = 1;

  return jsonb_build_object(
    'current', jsonb_build_object('month', cm, 'income', inc, 'tax', _tax(inc)),
    'filing', filing,
    'next', jsonb_build_object('month', cm, 'from', _dlabel(nx), 'to', _dlabel(nx + interval '14 days')),
    'debt', _debt(u),
    'returns', rets, 'notices', notes,
    'treasury', jsonb_build_object('casino', coalesce(tr.casino_total, 0),
                                   'tax', coalesce(tr.tax_total, 0), 'benefit', coalesce(tr.benefit_total, 0),
                                   'confiscated', coalesce(tr.confiscated_total, 0),
                                   'wage', coalesce(tr.wage_total, 0), 'fee', coalesce(tr.fee_total, 0)),
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
-- 重賞の名前を府中・京都・中京に合わせる（メインレースはその競馬場で行う）
alter table public.keiba_names add column if not exists venue int not null default 5;
do $$
declare r record;
begin
  for r in select * from (values
      ('g1', 0, '白浜スプリントカップ', '中京スプリントカップ', 1, '芝', 1200),
      ('g1', 2, '風見マイルチャンピオン', '府中マイルチャンピオン', 5, '芝', 1600),
      ('g1', 3, '銀杏ダートクラシック', '京都ダートクラシック', 2, 'ダ', 1900),
      ('sat', 1, '風見ステークス', '府中ステークス', 5, '芝', 1400),
      ('sat', 2, '白浜杯', '中京杯', 1, 'ダ', 1800),
      ('sat', 3, '銀杏賞', '京都賞', 2, '芝', 1800)) v(kind, idx, old, new, venue, surface, dist) loop
    update public.keiba_names set name = r.new, venue = r.venue, surface = r.surface, dist = r.dist
     where kind = r.kind and idx = r.idx and name = r.old;
    update public.keiba_races set name = r.new where name = r.old;
  end loop;
end $$;
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
  perform _kb_make_race(d, 29, coalesce(nr.venue, 5), 11, posttime, nr.name, nr.grade, null, nr.cond, nr.surface, nr.dist,
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
-- 送金（口座番号で相手を指定。手数料1%・最低1 X は国庫へ。登録から7日たつまで送金も受け取りもできない）
-- ---------------------------------------------------------------------
create or replace function public._new_acct() returns text
language plpgsql volatile set search_path = public as $$
declare a text; used int; lo int := 10000; span int := 90000;
begin
  -- 5けた（10000〜99999）。9割近く使ったら6けたにする
  select (select count(*) from profiles where char_length(account_no) = 5)
       + (select count(*) from companies where char_length(cid) = 5) into used;
  if used >= 85000 then lo := 100000; span := 900000; end if;
  loop
    a := (lo + floor(random() * span))::int::text;
    exit when not exists (select 1 from profiles where account_no = a)
          and not exists (select 1 from companies where cid = a);
  end loop;
  return a;
end $$;

do $$
declare r record;
begin
  -- 前の7けたの口座番号は5けたのIDに変える
  update public.profiles set account_no = null where char_length(account_no) = 7;
  for r in select id from public.profiles where account_no is null loop
    update public.profiles set account_no = public._new_acct() where id = r.id;
  end loop;
end $$;

create or replace function public._xfer_fee(amt bigint) returns bigint
language sql immutable as $$ select greatest(1, floor(amt * 0.01))::bigint $$;

-- IDから相手（ユーザーか会社）をさがす
create or replace function public._find_id(p_to text, out rid uuid, out rcomp int, out rname text, out rcreated timestamptz)
language plpgsql stable set search_path = public as $$
declare k text := btrim(coalesce(p_to, ''));
begin
  select id, nickname, created_at into rid, rname, rcreated from profiles where account_no = k;
  if found then return; end if;
  select id, name into rcomp, rname from companies where cid = _cid_norm(k) and status = 'active';
  if found then return; end if;
  if exists (select 1 from companies where cid = _cid_norm(k) and status = 'suspended') then raise exception 'その会社はいま休業中です'; end if;
  if exists (select 1 from companies where cid = _cid_norm(k) and status in ('closed', 'bankrupt')) then raise exception 'その会社はもうありません（廃業・倒産）'; end if;
  raise exception 'そのIDの人や会社は見つかりません';
end $$;

-- 送金できるか調べる（だめなら理由を出す）。src_comp があれば会社から送る
drop function if exists public._xfer_check(uuid, text, bigint);
create or replace function public._xfer_check(u uuid, p_to text, p_amount bigint, src_comp int,
  out rid uuid, out rcomp int, out rnick text, out fee bigint)
language plpgsql set search_path = public as $$
declare me profiles; c companies; t record; okday timestamptz; have bigint;
begin
  select * into me from profiles where id = u;
  if p_amount is null or p_amount < 1 or p_amount > 1000000000000 then raise exception '送る額は1 X以上にしてください'; end if;
  select * into t from _find_id(p_to);
  if src_comp is null then
    if t.rid = u then raise exception '自分には送れません'; end if;
    okday := me.created_at + interval '7 days';
    if _now() < okday then raise exception '登録から7日たつまで送金できません（%から送れます）', _dlabel(okday); end if;
    if _debt(u) > 0 then raise exception '税金の滞納があるので送金できません'; end if;
    have := me.balance;
  else
    select * into c from companies where id = src_comp and owner = u and status = 'active';
    if not found then raise exception 'この会社からは送れません'; end if;
    if t.rcomp = src_comp then raise exception '同じ会社には送れません'; end if;
    have := c.balance;
  end if;
  if t.rid is not null and _now() < t.rcreated + interval '7 days' then
    raise exception '相手は登録から7日たっていないので、まだ受け取れません';
  end if;
  fee := _xfer_fee(p_amount);
  if have < p_amount + fee then
    raise exception 'AiliNaXが足りません（手数料 % X をふくめて % X 必要です）', fee, p_amount + fee;
  end if;
  rid := t.rid; rcomp := t.rcomp; rnick := t.rname;
end $$;

-- 会社のお金を動かして帳簿に書く
create or replace function public._corp_move(cid_int int, amt bigint, k text, memo text) returns bigint
language plpgsql set search_path = public as $$
declare b bigint;
begin
  update companies set balance = balance + amt where id = cid_int returning balance into b;
  if b < 0 then raise exception '会社のお金が足りません'; end if;
  insert into corp_ledger(company_id, kind, amount, memo, balance_after) values (cid_int, k, amt, memo, b);
  -- 役所の判決で払いきれていない賠償金があれば、入ってきた分から取り立てる
  if amt > 0 and k <> 'court' and exists (select 1 from court_cases where defendant_comp = cid_int and comp_unpaid > 0) then
    perform _court_collect_comp(cid_int, amt);
    select balance into b from companies where id = cid_int;
  end if;
  return b;
end $$;

-- 受け取る側に入れる（ユーザーなら残高へ、会社なら会社のお金へ）
create or replace function public._credit(rid uuid, rcomp int, amt bigint, from_name text, from_id text) returns void
language plpgsql set search_path = public as $$
declare c companies;
begin
  if rid is not null then
    perform _give(rid, amt);
    perform _log(rid, 'receive', 0, amt, jsonb_build_object('from', from_name, 'id', from_id));
    perform _notice(rid, format('%s（ID %s）から %s X が届きました。', from_name, from_id, _fmt(amt)));
  else
    select * into c from companies where id = rcomp;
    perform _corp_move(rcomp, amt, 'receive', format('%s（ID %s）から入金', from_name, from_id));
    perform _notice(c.owner, format('会社「%s」に %s（ID %s）から %s X が入りました。', c.name, from_name, from_id, _fmt(amt)));
  end if;
end $$;

drop function if exists public.transfer_preview(text, bigint);
create or replace function public.transfer_preview(p_to text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from _xfer_check(_me(), p_to, p_amount, null);
  return jsonb_build_object('nickname', c.rnick, 'company', c.rcomp is not null, 'amount', p_amount, 'fee', c.fee, 'total', p_amount + c.fee);
end $$;

create or replace function public.transfer_send(p_to text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c record; me profiles;
begin
  select * into me from profiles where id = u for update;
  select * into c from _xfer_check(u, p_to, p_amount, null);
  update profiles set balance = balance - (p_amount + c.fee) where id = u;
  update treasury set balance = balance + c.fee, fee_total = fee_total + c.fee where id = 1;
  perform _log(u, 'send', p_amount + c.fee, 0, jsonb_build_object('to', c.rnick, 'id', btrim(p_to), 'amount', p_amount, 'fee', c.fee));
  perform _credit(c.rid, c.rcomp, p_amount, me.nickname || ' さん', me.account_no);
  return jsonb_build_object('nickname', c.rnick, 'amount', p_amount, 'fee', c.fee, 'balance', _bal(u));
end $$;

-- ---------------------------------------------------------------------
-- 仕事（ミニゲーム。1日8回まで。給料は国庫から。給料は所得として税金の対象）
--   1回5問。1問正解ごとに4 X、全問正解でボーナス5 X（最大25 X）
-- ---------------------------------------------------------------------
create table if not exists public.work_jobs (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,
  day        date not null,
  started_at timestamptz not null default now(),
  answers    jsonb not null,
  done       boolean not null default false,
  correct    int,
  pay        bigint
);
create index if not exists work_jobs_user_idx on public.work_jobs(user_id, day);
alter table public.work_jobs enable row level security;
revoke all on public.work_jobs from anon, authenticated;
alter table public.treasury add column if not exists wage_total bigint not null default 0;
alter table public.treasury add column if not exists issued_total bigint not null default 0;
-- 国庫に248億 X を発行（1回だけ）
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'issue_24800000000') then
    update public.treasury set balance = balance + 24800000000, issued_total = issued_total + 24800000000 where id = 1;
    insert into public.app_settings values ('issue_24800000000', now()::text);
  end if;
end $$;

create or replace function public.work_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); today date := _kb_jday(_now());
begin
  return jsonb_build_object(
    'limit', 8,
    'used', (select count(*) from work_jobs where user_id = u and day = today),
    'today_pay', (select coalesce(sum(pay), 0) from work_jobs where user_id = u and day = today and done),
    'total_pay', (select coalesce(sum(pay), 0) from work_jobs where user_id = u and done),
    'balance', _bal(u));
end $$;

-- 仕事をはじめる（問題を出す。答えはサーバーだけが持つ）
create or replace function public.work_start(p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _me(); today date := _kb_jday(_now()); qs jsonb := '[]'; ans jsonb := '[]';
  i int; a int; b int; op text; v int; items text[][]; pick int; grid text[]; target text; pool text[]; jid bigint; k int;
begin
  if (select count(*) from work_jobs where user_id = u and day = today) >= 8 then
    raise exception 'きょうの仕事はおしまいです（1日8回まで）。また明日どうぞ';
  end if;
  if p_kind = 'calc' then
    for i in 1..5 loop
      op := (array['+','−','×'])[1 + floor(random() * 3)::int];
      if op = '×' then a := 2 + floor(random() * 18)::int; b := 2 + floor(random() * 8)::int; v := a * b;
      elsif op = '+' then a := 10 + floor(random() * 90)::int; b := 10 + floor(random() * 90)::int; v := a + b;
      else a := 30 + floor(random() * 70)::int; b := 1 + floor(random() * (a - 1))::int; v := a - b; end if;
      qs := qs || jsonb_build_object('q', format('%s %s %s', a, op, b));
      ans := ans || to_jsonb(v);
    end loop;
  elsif p_kind = 'sort' then
    -- 荷物を「食べもの」と「道具」に仕分ける
    items := array[['🍎','食べもの'],['🍞','食べもの'],['🍙','食べもの'],['🥕','食べもの'],['🍣','食べもの'],['🧀','食べもの'],
                   ['🍌','食べもの'],['🍇','食べもの'],['🔨','道具'],['🔧','道具'],['✂️','道具'],['🪛','道具'],
                   ['📎','道具'],['🧹','道具'],['🪚','道具'],['📏','道具']];
    for i in 1..5 loop
      pick := 1 + floor(random() * 16)::int;
      qs := qs || jsonb_build_object('q', items[pick][1]);
      ans := ans || to_jsonb(items[pick][2]);
    end loop;
  elsif p_kind = 'count' then
    -- 棚の中から、言われた品物がいくつあるか数える
    pool := array['📦','🧴','🧻','🥫','🧃','🧽'];
    for i in 1..5 loop
      target := pool[1 + floor(random() * 6)::int];
      grid := '{}'; v := 0;
      for k in 1..20 loop
        grid := grid || pool[1 + floor(random() * 6)::int];
        if grid[k] = target then v := v + 1; end if;
      end loop;
      qs := qs || jsonb_build_object('q', target, 'grid', to_jsonb(grid));
      ans := ans || to_jsonb(v);
    end loop;
  else
    raise exception '知らない仕事です';
  end if;
  insert into work_jobs(user_id, kind, day, started_at, answers) values (u, p_kind, today, _now(), ans) returning id into jid;
  return jsonb_build_object('id', jid, 'kind', p_kind, 'questions', qs, 'limit_sec', 120);
end $$;

-- 答えを出して給料をもらう
create or replace function public.work_submit(p_job bigint, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); j work_jobs; i int; c int := 0; wage bigint; secs numeric;
begin
  select * into j from work_jobs where id = p_job and user_id = u for update;
  if not found then raise exception '仕事が見つかりません'; end if;
  if j.done then raise exception 'この仕事はもう終わっています'; end if;
  secs := extract(epoch from _now() - j.started_at);
  for i in 0..4 loop
    if p_answers -> i is not null and btrim(p_answers ->> i) = btrim(j.answers ->> i) then c := c + 1; end if;
  end loop;
  if secs > 120 then c := 0; end if;             -- 時間切れ
  wage := c * 4 + case when c = 5 then 5 else 0 end;
  update work_jobs set done = true, correct = c, pay = wage where id = j.id;
  if wage > 0 then
    update treasury set balance = balance - wage, wage_total = wage_total + wage where id = 1;
    perform _give(u, wage);
    perform _log(u, 'work', 0, wage, jsonb_build_object('kind', j.kind, 'correct', c));
  end if;
  return jsonb_build_object('correct', c, 'pay', wage, 'answers', j.answers, 'late', secs > 120) || work_state();
end $$;

-- ---------------------------------------------------------------------
-- 情報（通貨のようす・最近の競馬の大当たり・お金持ちランキング）
-- ---------------------------------------------------------------------
create or replace function public.info_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); tr treasury;
begin
  select * into tr from treasury where id = 1;
  return jsonb_build_object(
    'players', (select count(*) from profiles),
    'companies', (select count(*) from companies where status = 'active'),
    'wage', coalesce(tr.wage_total, 0), 'fee', coalesce(tr.fee_total, 0),
    -- 競馬億万長者：今週（月曜から）の競馬の勝ち（払戻 − 賭け金）の合計
    'week_from', _dlabel((_kb_jday(_now()) - (extract(isodow from _kb_jday(_now()))::int - 1))::timestamp at time zone 'Asia/Tokyo'),
    'jackpots', (select coalesce(jsonb_agg(z order by z.net desc), '[]'::jsonb) from (
        select p.nickname, _badge(p.id) badge, sum(t.payout - t.amount)::bigint net, sum(t.payout)::bigint payout, sum(t.amount)::bigint bet,
               count(*) filter (where t.payout > 0) hits, max(t.payout)::bigint best
          from keiba_tickets t join profiles p on p.id = t.user_id join keiba_races r on r.id = t.race_id
         where t.payout is not null and r.day >= _kb_jday(_now()) - (extract(isodow from _kb_jday(_now()))::int - 1)
         group by p.id, p.nickname having sum(t.payout - t.amount) > 0
         order by net desc limit 20) z),
    'balance', _bal(u));
end $$;

-- ---------------------------------------------------------------------
-- 企業・銀行
--   申請料1,000 X（国庫へ）で申請 → 管理者が審査（却下なら申請料を返す）→ 企業として活動
--   企業ページに商品（購入ボタン）を置ける。買うと代金が会社へ（買う人が手数料1%・最低1 Xを払う）
--   会社のお金：会社から送金（会社間取引もOK・手数料1%）、自分に引き出す（給料あつかいで所得）、自分から入れる
--   銀行：口座を開いて預金・引き出し。利息は銀行が決めた1日あたりの%で、銀行の会社のお金から毎日払う
-- ---------------------------------------------------------------------
create or replace function public._is_admin(u uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from app_settings where key = 'admins' and u::text = any(string_to_array(value, ',')))
$$;

create or replace function public._my_corp(u uuid, p_cid text) returns companies
language plpgsql stable set search_path = public as $$
declare c companies;
begin
  select * into c from companies where cid = _cid_norm(p_cid) and owner = u;
  if not found then raise exception 'あなたの会社ではありません'; end if;
  return c;
end $$;

-- 銀行の利息を、前回から今日までの分まとめて払う
create or replace function public._bank_accrue(cid_int int, uid uuid) returns void
language plpgsql set search_path = public as $$
declare a bank_accounts; c companies; days int; owed numeric; pay bigint;
begin
  select * into a from bank_accounts where company_id = cid_int and user_id = uid for update;
  if not found then return; end if;
  days := _kb_jday(_now()) - a.interest_day;
  if days <= 0 then return; end if;
  select * into c from companies where id = cid_int for update;
  owed := a.unpaid + a.balance * c.rate / 100 * days;
  pay := least(floor(owed), c.balance)::bigint;
  if pay > 0 then
    perform _corp_move(cid_int, -pay, 'interest', '預金の利息');
    update profiles set balance = balance + pay where id = uid;
    perform _log(uid, 'interest', 0, pay, jsonb_build_object('bank', c.name));
  end if;
  update bank_accounts set balance = balance, interest_day = _kb_jday(_now()),
         interest_total = interest_total + pay, unpaid = owed - pay
   where company_id = cid_int and user_id = uid;
end $$;

create or replace function public._bank_accrue_all(cid_int int) returns void
language plpgsql set search_path = public as $$
declare r record;
begin
  for r in select user_id from bank_accounts where company_id = cid_int and status = 'active' loop
    perform _bank_accrue(cid_int, r.user_id);
  end loop;
end $$;

-- 会社の見た目（だれでも見られる部分）
create or replace function public._corp_card(c companies, u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'form', c.form, 'kind', c.kind, 'description', c.description,
    'owner', (select nickname from profiles where id = c.owner), 'owner_badge', _badge(c.owner), 'rate', c.rate, 'status', c.status,
    'exchange', c.cid = (select value from app_settings where key = 'exchange_cid'), 'official', c.official, 'acct_mode', c.acct_mode,
    'acct_need_check', c.acct_need_check, 'loan_on', c.loan_on, 'loan_need_acct', c.loan_need_acct, 'loan_need_check', c.loan_need_check,
    'pinned', exists (select 1 from corp_pins where user_id = u and company_id = c.id),
    'mine', c.owner = u)
$$;

-- 会社をさがす（名前の一部かID）
create or replace function public.corp_search(p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); q text := btrim(coalesce(p_q, ''));
begin
  return (select coalesce(jsonb_agg(_corp_card(c, u) order by c.name), '[]'::jsonb) from (
    select * from companies
     where status in ('active', 'suspended') and (q = '' or name ilike '%' || q || '%' or cid = split_part(q, '-', 1) or description ilike '%' || q || '%')
     order by name limit 50) c);
end $$;

create or replace function public.corp_pins() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return (select coalesce(jsonb_agg(_corp_card(c, u) order by c.name), '[]'::jsonb)
            from companies c join corp_pins p on p.company_id = c.id and p.user_id = u where c.status in ('active', 'suspended'));
end $$;

create or replace function public.corp_pin(p_cid text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません'; end if;
  if p_on then insert into corp_pins values (u, c.id) on conflict do nothing;
  else delete from corp_pins where user_id = u and company_id = c.id; end if;
  return corp_pins();
end $$;

-- 会社のページ（商品と、銀行なら自分の口座）
create or replace function public.corp_page(p_cid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; acct bank_accounts;
begin
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません'; end if;
  if c.kind = '銀行' then perform _bank_accrue(c.id, u); end if;
  select * into acct from bank_accounts where company_id = c.id and user_id = u;
  return _corp_card(c, u) || jsonb_build_object(
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'price', price, 'description', description) order by id), '[]'::jsonb)
                from corp_items where company_id = c.id and active),
    'account', case when acct.user_id is null then null else jsonb_build_object('balance', acct.balance, 'interest_total', acct.interest_total, 'status', acct.status) end,
    'packs', (select coalesce(jsonb_agg(_pack_json(lp) order by lp.amount), '[]'::jsonb) from loan_packs lp where lp.company_id = c.id and lp.active and c.loan_on),
    'loans', (select coalesce(jsonb_agg(_loan_json(l) order by l.id desc), '[]'::jsonb) from loans l
               where l.company_id = c.id and l.user_id = u and l.status in ('pending', 'active')),
    'shares', c.shares, 'holders', _corp_holders(c.id),
    'balance', _bal(u));
end $$;

-- 買う（代金は会社へ。手数料1%・最低1 Xは買う人が払って国庫へ）
create or replace function public.corp_buy(p_item bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); it corp_items; c companies; me profiles; fee bigint; okday timestamptz; oid bigint;
begin
  select * into it from corp_items where id = p_item and active;
  if not found then raise exception 'その商品は売っていません'; end if;
  select * into c from companies where id = it.company_id and status = 'active';
  if not found then raise exception 'この会社はいま営業していません（休業中など）'; end if;
  if c.owner = u then raise exception '自分の会社の商品は買えません'; end if;
  select * into me from profiles where id = u for update;
  okday := me.created_at + interval '7 days';
  if _now() < okday then raise exception '登録から7日たつまで買い物はできません（%から）', _dlabel(okday); end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので買えません'; end if;
  fee := _xfer_fee(it.price);
  if me.balance < it.price + fee then
    raise exception 'AiliNaXが足りません（手数料 % X をふくめて % X 必要です）', fee, it.price + fee;
  end if;
  update profiles set balance = balance - (it.price + fee) where id = u;
  update treasury set balance = balance + fee, fee_total = fee_total + fee where id = 1;
  insert into corp_orders(item_id, company_id, buyer, item_name, price, fee, note)
  values (it.id, c.id, u, it.name, it.price, fee, nullif(left(btrim(coalesce(p_note, '')), 200), '')) returning id into oid;
  perform _corp_move(c.id, it.price, 'sale', format('「%s」の売上（注文 #%s）', it.name, oid));
  perform _log(u, 'buy', it.price + fee, 0, jsonb_build_object('company', c.name, 'item', it.name, 'order', oid));
  perform _notice(c.owner, format('【注文 #%s】%s さんが「%s」を %s X で買いました。会社のページから品物を渡してください。', oid, me.nickname, it.name, _fmt(it.price)));
  return jsonb_build_object('order', oid, 'price', it.price, 'fee', fee, 'balance', _bal(u));
end $$;

create or replace function public.my_orders() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'company', c.name, 'cid', c.cid, 'item', o.item_name,
            'price', o.price, 'fee', o.fee, 'note', o.note, 'status', o.status, 'at', _dlabel(o.created_at)) order by o.id desc), '[]'::jsonb)
            from (select * from corp_orders where buyer = u order by id desc limit 50) o join companies c on c.id = o.company_id);
end $$;

-- 銀行：口座を開く・預ける・引き出す・自分の口座一覧
create or replace function public.bank_open(p_cid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  select * into c from companies where cid = _cid_norm(p_cid) and status = 'active' and kind = '銀行';
  if not found then raise exception 'その銀行は見つかりません'; end if;
  if exists (select 1 from bank_accounts where company_id = c.id and user_id = u) then raise exception 'もう口座があります（申込中をふくむ）'; end if;
  if c.acct_mode = 'off' and c.owner <> u then raise exception 'この銀行はいま口座の受付をしていません'; end if;
  if c.acct_need_check and c.owner <> u and not coalesce((_badge(u)->>'ok')::boolean, false) then
    raise exception 'この銀行で口座を開くには、オレンジのチェックが必要です';
  end if;
  insert into bank_accounts(company_id, user_id, interest_day, status)
  values (c.id, u, _kb_jday(_now()), case when c.acct_mode = 'auto' or c.owner = u then 'active' else 'pending' end);
  if c.acct_mode <> 'auto' and c.owner <> u then
    perform _notice(c.owner, format('【口座の申込】%s さん（ID %s）が「%s」の口座を申し込みました。仕事タブの企業ページで許可できます。',
                    (select nickname from profiles where id = u), (select account_no from profiles where id = u), c.name));
  end if;
  return corp_page(p_cid);
end $$;

create or replace function public.bank_deposit(p_cid text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  select * into c from companies where cid = _cid_norm(p_cid) and status = 'active' and kind = '銀行';
  if not found then raise exception 'その銀行は見つかりません'; end if;
  if not exists (select 1 from bank_accounts where company_id = c.id and user_id = u) then raise exception '先に口座を開いてください'; end if;
  if (select status from bank_accounts where company_id = c.id and user_id = u) <> 'active' then raise exception '口座はまだ銀行の許可待ちです'; end if;
  if p_amount is null or p_amount < 1 then raise exception '1 X以上にしてください'; end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので預けられません'; end if;
  perform _bank_accrue(c.id, u);
  perform _take(u, p_amount);
  update bank_accounts set balance = balance + p_amount where company_id = c.id and user_id = u;
  perform _log(u, 'deposit', p_amount, 0, jsonb_build_object('bank', c.name));
  return corp_page(p_cid);
end $$;

create or replace function public.bank_withdraw(p_cid text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; a bank_accounts;
begin
  select * into c from companies where cid = _cid_norm(p_cid) and kind = '銀行';
  if not found then raise exception 'その銀行は見つかりません'; end if;
  perform _bank_accrue(c.id, u);
  select * into a from bank_accounts where company_id = c.id and user_id = u for update;
  if not found then raise exception '口座がありません'; end if;
  if p_amount is null or p_amount < 1 or p_amount > a.balance then raise exception '引き出せるのは % X までです', a.balance; end if;
  update bank_accounts set balance = balance - p_amount where company_id = c.id and user_id = u;
  update profiles set balance = balance + p_amount where id = u;
  perform _log(u, 'withdraw', 0, p_amount, jsonb_build_object('bank', c.name));
  if c.status in ('active', 'suspended') then return corp_page(p_cid); end if;
  return jsonb_build_object('balance', _bal(u));
end $$;

create or replace function public.my_banks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r record;
begin
  for r in select company_id from bank_accounts where user_id = u and status = 'active' loop perform _bank_accrue(r.company_id, u); end loop;
  return jsonb_build_object('accounts', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'rate', c.rate, 'balance', a.balance,
            'interest_total', a.interest_total, 'active', c.status = 'active', 'status', a.status) order by c.name), '[]'::jsonb)
            from bank_accounts a join companies c on c.id = a.company_id where a.user_id = u),
    'loans', my_loans());
end $$;

-- 企業の申請
drop function if exists public.corp_apply(text, text, text);
create or replace function public.corp_apply(p_name text, p_form text, p_pre boolean, p_kind text, p_desc text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); base text := btrim(coalesce(p_name, '')); nm text;
begin
  if char_length(base) < 1 or char_length(base) > 24 then raise exception '会社名は1〜24文字です'; end if;
  if p_form not in ('株式会社', '有限会社', '合同会社') then raise exception '会社の形（株式会社・有限会社・合同会社）をえらんでください'; end if;
  if base ~ '(株式会社|有限会社|合同会社|合資会社|合名会社)' then raise exception '会社名には「株式会社」などを入れないでください（下でえらべます）'; end if;
  if p_kind not in ('一般', '銀行', '証券') then raise exception '会社の種類をえらんでください'; end if;
  if p_kind = '銀行' and p_form <> '株式会社' then raise exception '銀行は株式会社だけです'; end if;
  if p_kind = '証券' and p_form <> '株式会社' then raise exception '証券会社は株式会社だけです'; end if;
  nm := case when coalesce(p_pre, true) then p_form || base else base || p_form end;
  if (select count(*) from companies where owner = u and status in ('pending', 'active', 'suspended') and not official) >= 3 then
    raise exception '会社は1人3つまでです';
  end if;
  if exists (select 1 from companies where lower(name) = lower(nm) and status not in ('rejected', 'closed', 'bankrupt')) then
    raise exception 'その名前の会社はもうあります';
  end if;
  perform _take(u, 1000);
  update treasury set balance = balance + 1000, fee_total = fee_total + 1000 where id = 1;
  perform _log(u, 'corp_fee', 1000, 0, jsonb_build_object('company', nm));
  insert into companies(cid, owner, name, form, kind, description, fee_paid)
  values (_new_ccode(), u, nm, p_form, p_kind, left(coalesce(p_desc, ''), 1000), 1000);
  return my_corps();
end $$;

-- 自分の会社（申請中もふくむ）
create or replace function public.my_corps() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return jsonb_build_object('corps', (select coalesce(jsonb_agg(jsonb_build_object(
      'cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'form', c.form, 'kind', c.kind, 'description', c.description, 'status', c.status, 'reason', c.reason,
      'balance', c.balance, 'rate', c.rate, 'ca', c.ca, 'court_lock', c.court_lock,
      'closed_at', case when c.closed_at is null then null else _dlabel(c.closed_at) end,
      'owed', (select coalesce(sum(price), 0) from corp_orders where company_id = c.id and status = 'paid'),
      'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'price', i.price,
                  'description', i.description, 'active', i.active) order by i.id), '[]'::jsonb) from corp_items i where i.company_id = c.id),
      'orders', (select coalesce(jsonb_agg(z order by z.id desc), '[]'::jsonb) from (
                  select o.id, o.item_name item, o.price, o.note, o.status, _dlabel(o.created_at) at, p.nickname buyer, p.account_no buyer_id
                    from corp_orders o join profiles p on p.id = o.buyer where o.company_id = c.id order by o.id desc limit 30) z),
      'ledger', (select coalesce(jsonb_agg(z order by z.id desc), '[]'::jsonb) from (
                  select id, kind, amount, memo, balance_after, _dlabel(created_at) at from corp_ledger where company_id = c.id order by id desc limit 20) z),
      'jobs', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'title', j.title, 'description', j.description,
                 'wage', j.wage, 'contact', j.contact, 'active', j.active) order by j.id desc), '[]'::jsonb) from corp_jobs j where j.company_id = c.id),
      'applies', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title', j.title, 'nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id),
                 'message', a.message, 'at', _dlabel(a.created_at)) order by a.id), '[]'::jsonb)
                 from corp_applies a join corp_jobs j on j.id = a.job_id join profiles p on p.id = a.user_id
                 where j.company_id = c.id and a.status = 'waiting'),
      'members', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'role', m.role,
                 'salary', m.salary, 'paid_total', m.paid_total) order by m.joined_at), '[]'::jsonb)
                 from corp_members m join profiles p on p.id = m.user_id where m.company_id = c.id),
      'deposits', (select coalesce(sum(balance), 0) from bank_accounts where company_id = c.id),
      'accounts', (select count(*) from bank_accounts where company_id = c.id and status = 'active'),
      'official', c.official, 'acct_mode', c.acct_mode, 'fx_pairs', c.fx_pairs, 'fx_fee', c.fx_fee,
      'acct_need_check', c.acct_need_check, 'loan_on', c.loan_on, 'loan_need_acct', c.loan_need_acct, 'loan_need_check', c.loan_need_check,
      'fx_open_orders', (select count(*) from fx_orders where exch_id = c.id and status = 'open'),
      'acct_requests', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id))), '[]'::jsonb)
                 from bank_accounts a join profiles p on p.id = a.user_id where a.company_id = c.id and a.status = 'pending'),
      'packs', (select coalesce(jsonb_agg(_pack_json(lp) order by lp.id), '[]'::jsonb) from loan_packs lp where lp.company_id = c.id),
      'loan_requests', (select coalesce(jsonb_agg(_loan_json(l) order by l.id), '[]'::jsonb) from loans l where l.company_id = c.id and l.status = 'pending'),
      'loans_active', (select coalesce(jsonb_agg(_loan_json(l) order by l.due_at), '[]'::jsonb) from loans l where l.company_id = c.id and l.status = 'active'),
      'shares', c.shares, 'holders', _corp_holders(c.id)
    ) order by c.id), '[]'::jsonb) from companies c where c.owner = u and c.status <> 'rejected'),
    'rejected', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'reason', reason) order by id desc), '[]'::jsonb)
                   from (select * from companies where owner = u and status = 'rejected' order by id desc limit 5) r),
    'balance', _bal(u));
end $$;

-- 会社ページの更新（説明・金利）
create or replace function public.corp_update(p_cid text, p_desc text, p_rate numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if p_rate is not null and (p_rate < 0 or p_rate > 10) then raise exception '金利は1日あたり0〜10%%です'; end if;
  if c.kind = '銀行' and p_rate is not null and p_rate <> c.rate then perform _bank_accrue_all(c.id); end if;
  update companies set description = left(coalesce(p_desc, description), 1000),
         rate = case when kind = '銀行' then coalesce(p_rate, rate) else 0 end
   where id = c.id;
  return my_corps();
end $$;

-- 商品（購入ボタン）を追加・変更
create or replace function public.corp_item_save(p_cid text, p_item bigint, p_name text, p_price bigint, p_desc text, p_active boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; nm text := btrim(coalesce(p_name, ''));
begin
  c := _my_corp(u, p_cid);
  if char_length(nm) < 1 or char_length(nm) > 40 then raise exception '商品名は1〜40文字です'; end if;
  if p_price is null or p_price < 1 or p_price > 1000000000000 then raise exception '値段は1 X以上にしてください'; end if;
  if p_item is null then
    if (select count(*) from corp_items where company_id = c.id) >= 30 then raise exception '商品は30個までです'; end if;
    insert into corp_items(company_id, name, price, description, active) values (c.id, nm, p_price, left(coalesce(p_desc, ''), 300), coalesce(p_active, true));
  else
    update corp_items set name = nm, price = p_price, description = left(coalesce(p_desc, ''), 300), active = coalesce(p_active, active)
     where id = p_item and company_id = c.id;
    if not found then raise exception 'その商品はありません'; end if;
  end if;
  return my_corps();
end $$;

-- 注文の品物を渡した
create or replace function public.corp_order_done(p_order bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); o corp_orders; c companies;
begin
  select * into o from corp_orders where id = p_order for update;
  if not found then raise exception '注文が見つかりません'; end if;
  select * into c from companies where id = o.company_id and owner = u;
  if not found then raise exception 'あなたの会社の注文ではありません'; end if;
  update corp_orders set status = 'done', done_at = _now() where id = o.id;
  perform _notice(o.buyer, format('【注文 #%s】%s の「%s」を受け取りました（会社が「渡した」にしました）。', o.id, c.name, o.item_name));
  return my_corps();
end $$;

-- 会社から送金（会社間取引・ユーザーへの支払い）
create or replace function public.corp_send(p_cid text, p_to text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; x record;
begin
  c := _my_corp(u, p_cid);
  select * into x from _xfer_check(u, p_to, p_amount, c.id);
  perform _corp_move(c.id, -(p_amount + x.fee), 'send', format('%s（ID %s）へ送金（手数料 %s）', x.rnick, btrim(p_to), x.fee));
  update treasury set balance = balance + x.fee, fee_total = fee_total + x.fee where id = 1;
  perform _credit(x.rid, x.rcomp, p_amount, '会社「' || c.name || '」', _cfull(c));
  return my_corps();
end $$;

-- 会社のお金を自分に引き出す（給料あつかい＝所得）／自分のお金を会社に入れる
create or replace function public.corp_withdraw(p_cid text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  if p_amount is null or p_amount < 1 or p_amount > c.balance then raise exception '引き出せるのは % X までです', c.balance; end if;
  perform _corp_move(c.id, -p_amount, 'salary', '社長への給料');
  perform _give(u, p_amount);
  perform _log(u, 'salary', 0, p_amount, jsonb_build_object('company', c.name));
  return my_corps();
end $$;

create or replace function public.corp_fund(p_cid text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  if p_amount is null or p_amount < 1 then raise exception '1 X以上にしてください'; end if;
  perform _take(u, p_amount);
  perform _log(u, 'fund', p_amount, 0, jsonb_build_object('company', c.name));
  perform _corp_move(c.id, p_amount, 'fund', '社長から入金');
  return my_corps();
end $$;

-- 求人・社員・給料 ----------------------------------------------------
--   社長は求人を出せる（仕事内容・給料の目安・連絡先 Discord / X）
--   求人に「応募」→ 社長が採用すると社員に。社長は社員に給料を払える（会社のお金から。受け取った人の所得）
create table if not exists public.corp_jobs (
  id          bigserial primary key,
  company_id  int not null references public.companies(id) on delete cascade,
  title       text not null,
  description text not null default '',
  wage        text not null default '',
  contact     text not null default '',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create table if not exists public.corp_applies (
  id         bigserial primary key,
  job_id     bigint not null references public.corp_jobs(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  message    text,
  status     text not null default 'waiting',   -- waiting / hired / declined
  created_at timestamptz not null default now(),
  unique (job_id, user_id)
);
create table if not exists public.corp_members (
  company_id int not null references public.companies(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role       text not null default '社員',
  salary     bigint not null default 0,          -- 1回の給料
  paid_total bigint not null default 0,
  joined_at  timestamptz not null default now(),
  primary key (company_id, user_id)
);
alter table public.corp_jobs    enable row level security;
alter table public.corp_applies enable row level security;
alter table public.corp_members enable row level security;
revoke all on public.corp_jobs, public.corp_applies, public.corp_members from anon, authenticated;

-- 求人を出す・変える
create or replace function public.corp_job_save(p_cid text, p_job bigint, p_title text, p_desc text, p_wage text, p_contact text, p_active boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; t text := btrim(coalesce(p_title, ''));
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  if char_length(t) < 1 or char_length(t) > 40 then raise exception '求人のタイトルは1〜40文字です'; end if;
  if p_job is null then
    if (select count(*) from corp_jobs where company_id = c.id and active) >= 10 then raise exception '出せる求人は10件までです'; end if;
    insert into corp_jobs(company_id, title, description, wage, contact, active)
    values (c.id, t, left(coalesce(p_desc, ''), 1000), left(coalesce(p_wage, ''), 60), left(coalesce(p_contact, ''), 120), coalesce(p_active, true));
  else
    update corp_jobs set title = t, description = left(coalesce(p_desc, ''), 1000), wage = left(coalesce(p_wage, ''), 60),
           contact = left(coalesce(p_contact, ''), 120), active = coalesce(p_active, active)
     where id = p_job and company_id = c.id;
    if not found then raise exception 'その求人はありません'; end if;
  end if;
  return my_corps();
end $$;

-- 求人の一覧（だれでも）
create or replace function public.job_list(p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); q text := btrim(coalesce(p_q, ''));
begin
  return (select coalesce(jsonb_agg(z order by z.id desc), '[]'::jsonb) from (
    select j.id, j.title, j.description, j.wage, j.contact, c.name company, c.cid, c.kind, c.form,
           (select status from corp_applies a where a.job_id = j.id and a.user_id = u) applied,
           exists (select 1 from corp_members m where m.company_id = c.id and m.user_id = u) member,
           c.owner = u mine
      from corp_jobs j join companies c on c.id = j.company_id
     where j.active and c.status = 'active'
       and (q = '' or j.title ilike '%' || q || '%' or c.name ilike '%' || q || '%' or j.description ilike '%' || q || '%')
     order by j.id desc limit 50) z);
end $$;

-- 応募する
create or replace function public.job_apply(p_job bigint, p_message text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); j corp_jobs; c companies; me profiles;
begin
  select * into j from corp_jobs where id = p_job and active;
  if not found then raise exception 'その求人はもう締め切られています'; end if;
  select * into c from companies where id = j.company_id and status = 'active';
  if not found then raise exception 'この会社はいま募集していません（休業中など）'; end if;
  if c.owner = u then raise exception '自分の会社の求人です'; end if;
  if exists (select 1 from corp_members where company_id = c.id and user_id = u) then raise exception 'もうこの会社の社員です'; end if;
  select * into me from profiles where id = u;
  insert into corp_applies(job_id, user_id, message) values (j.id, u, left(coalesce(p_message, ''), 300))
  on conflict (job_id, user_id) do update set message = excluded.message, status = 'waiting', created_at = now();
  perform _notice(c.owner, format('【応募】%s さん（ID %s）が「%s」の求人「%s」に応募しました。仕事タブの企業ページで採用できます。',
                                  me.nickname, me.account_no, c.name, j.title));
  return job_list('');
end $$;

-- 応募に答える（採用・見送り）
create or replace function public.corp_apply_answer(p_apply bigint, p_hire boolean, p_salary bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); a corp_applies; j corp_jobs; c companies;
begin
  select * into a from corp_applies where id = p_apply for update;
  if not found then raise exception '応募が見つかりません'; end if;
  select * into j from corp_jobs where id = a.job_id;
  select * into c from companies where id = j.company_id and owner = u;
  if not found then raise exception 'あなたの会社への応募ではありません'; end if;
  if p_hire then
    insert into corp_members(company_id, user_id, salary) values (c.id, a.user_id, greatest(coalesce(p_salary, 0), 0))
    on conflict do nothing;
    update corp_applies set status = 'hired' where id = a.id;
    perform _notice(a.user_id, format('【採用】「%s」に採用されました（求人「%s」）。', c.name, j.title));
  else
    update corp_applies set status = 'declined' where id = a.id;
    perform _notice(a.user_id, format('「%s」の求人「%s」は今回は見送りになりました。', c.name, j.title));
  end if;
  return my_corps();
end $$;

-- 社員の給料・役職を決める／やめてもらう
create or replace function public.corp_member_set(p_cid text, p_user text, p_salary bigint, p_role text, p_remove boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; m uuid;
begin
  c := _my_corp(u, p_cid);
  select id into m from profiles where account_no = btrim(coalesce(p_user, ''));
  if not found or not exists (select 1 from corp_members where company_id = c.id and user_id = m) then raise exception 'その社員はいません'; end if;
  if p_remove then
    delete from corp_members where company_id = c.id and user_id = m;
    perform _notice(m, format('「%s」をやめることになりました。', c.name));
  else
    update corp_members set salary = greatest(coalesce(p_salary, salary), 0), role = left(coalesce(nullif(btrim(p_role), ''), role), 20)
     where company_id = c.id and user_id = m;
  end if;
  return my_corps();
end $$;

-- 給料を払う（p_user を指定すればその人だけ、空なら社員全員に決めた額）
create or replace function public.corp_pay(p_cid text, p_user text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; m record; amt bigint; total bigint := 0; n int := 0;
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  for m in select cm.*, p.nickname, p.account_no from corp_members cm join profiles p on p.id = cm.user_id
            where cm.company_id = c.id and (coalesce(p_user, '') = '' or p.account_no = btrim(p_user)) loop
    amt := case when coalesce(p_user, '') = '' then m.salary else p_amount end;
    continue when amt is null or amt < 1;
    perform _corp_move(c.id, -amt, 'payroll', format('%s さん（ID %s）に給料', m.nickname, m.account_no));
    perform _give(m.user_id, amt);
    perform _log(m.user_id, 'salary', 0, amt, jsonb_build_object('company', c.name));
    perform _notice(m.user_id, format('「%s」から給料 %s X が入りました。', c.name, _fmt(amt)));
    update corp_members set paid_total = paid_total + amt where company_id = c.id and user_id = m.user_id;
    total := total + amt; n := n + 1;
  end loop;
  if n = 0 then raise exception '給料を払う社員がいません（社員の給料が0か、IDがちがいます）'; end if;
  return my_corps() || jsonb_build_object('paid', total, 'people', n);
end $$;

-- 自分の勤め先
create or replace function public.my_jobs() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return jsonb_build_object(
    'members', (select coalesce(jsonb_agg(jsonb_build_object('company', c.name, 'cid', c.cid, 'role', m.role, 'salary', m.salary,
                  'paid_total', m.paid_total, 'since', _dlabel(m.joined_at)) order by m.joined_at), '[]'::jsonb)
                  from corp_members m join companies c on c.id = m.company_id where m.user_id = u),
    'applies', (select coalesce(jsonb_agg(jsonb_build_object('company', c.name, 'title', j.title, 'status', a.status,
                  'at', _dlabel(a.created_at)) order by a.id desc), '[]'::jsonb)
                  from corp_applies a join corp_jobs j on j.id = a.job_id join companies c on c.id = j.company_id where a.user_id = u));
end $$;

create or replace function public.job_quit(p_cid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  select * into c from companies where cid = _cid_norm(p_cid);
  delete from corp_members where company_id = c.id and user_id = u;
  if not found then raise exception 'その会社の社員ではありません'; end if;
  perform _notice(c.owner, format('社員が「%s」をやめました。', c.name));
  return my_jobs();
end $$;

-- 管理者・副管理者：審査など（国のお金のようすは管理者だけ）
create or replace function public.admin_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); tr treasury; rl text := _role(u); r jsonb;
begin
  if rl is null then raise exception '管理者だけが使えます'; end if;
  select * into tr from treasury where id = 1;
  r := jsonb_build_object('role', rl,
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'form', c.form, 'kind', c.kind, 'description', c.description,
                  'owner', p.nickname, 'owner_id', p.account_no, 'owner_badge', _badge(p.id), 'mine', c.owner = u, 'at', _dlabel(c.created_at)) order by c.id), '[]'::jsonb)
                  from companies c join profiles p on p.id = c.owner where c.status = 'pending'),
    'active', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'form', c.form, 'kind', c.kind, 'owner', p.nickname,
                  'status', c.status, 'court_lock', c.court_lock,
                  'balance', case when rl = 'admin' then c.balance end) order by c.name), '[]'::jsonb)
                  from companies c join profiles p on p.id = c.owner where c.status in ('active', 'suspended')),
    'fx_requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'amount', r.amount, 'contact', r.contact,
                     'nickname', p.nickname, 'uid', p.account_no, 'mine', r.user_id = u,
                     'ca', case when rl = 'admin' then p.ca end, 'at', _dlabel(r.created_at)) order by r.id), '[]'::jsonb)
                     from fx_requests r join profiles p on p.id = r.user_id where r.status = 'pending'),
    'cases', (select coalesce(jsonb_agg(_case_json(cc, u) order by cc.id), '[]'::jsonb) from court_cases cc where cc.status = 'open'),
    'fee_pct', _fx_fee_pct());
  if rl = 'admin' then
    r := r || jsonb_build_object(
      'treasury', to_jsonb(tr),
      'supply', (select coalesce(sum(balance), 0) from profiles),
      'corp_money', (select coalesce(sum(balance), 0) from companies),
      'bank_money', (select coalesce(sum(balance), 0) from bank_accounts),
      'ca_total', (select coalesce(sum(ca), 0) from profiles) + (select coalesce(sum(ca), 0) from companies)
                  + (select coalesce(sum(locked), 0) from fx_orders where side = 'buy' and status = 'open')
                  + (select coalesce(sum(amount), 0) from fx_requests where kind = 'out' and status = 'pending'),
      'ca_reserve', tr.ca_balance, 'ca_issued', tr.ca_issued,
      'subadmins', (select value from app_settings where key = 'subadmins'));
  end if;
  return r;
end $$;

create or replace function public.admin_corp_decide(p_cid text, p_ok boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  if not _is_staff(u) then raise exception '管理者だけが使えます'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) and status = 'pending' for update;
  if not found then raise exception '審査中の申請が見つかりません'; end if;
  if c.owner = u and _role(u) <> 'admin' then raise exception '自分の申請は審査できません'; end if;
  if p_ok then
    update companies set status = 'active', decided_at = _now() where id = c.id;
    perform _add_shares(c.id, c.owner, c.shares);
    perform _notice(c.owner, format('【企業申請】「%s」が許可されました。会社のIDは %s です（取引は最初の3けた %s だけでもできます）。仕事タブの「企業ページ」から商品などを設定できます。', c.name, _cfull(c), c.cid));
  else
    update companies set status = 'rejected', decided_at = _now(), reason = left(coalesce(p_reason, ''), 300), cid = 'x' || c.id where id = c.id;
    update profiles set balance = balance + c.fee_paid where id = c.owner;
    update treasury set balance = balance - c.fee_paid, fee_total = fee_total - c.fee_paid where id = 1;
    perform _log(c.owner, 'corp_refund', 0, c.fee_paid, jsonb_build_object('company', c.name));
    perform _notice(c.owner, format('【企業申請】「%s」は却下されました。%s 申請料 %s X は返しました。', c.name,
                    case when coalesce(p_reason, '') <> '' then '理由：' || p_reason || '。' else '' end, _fmt(c.fee_paid)));
  end if;
  return admin_state();
end $$;

-- ---------------------------------------------------------------------
-- 請求（請求書）
--   ユーザーや会社が、相手のID（ユーザーか会社）に「〇X 払ってください」と請求できる
--   請求された人（会社なら社長）が「払う」を押すと、ふつうの送金と同じに払われる（手数料1%・最低1 Xは払う側）
--   断る（請求された側）・取り消す（請求した側）もできる
-- ---------------------------------------------------------------------
create table if not exists public.invoices (
  id         bigserial primary key,
  from_user  uuid references public.profiles(id) on delete cascade,
  from_comp  int  references public.companies(id) on delete cascade,
  to_user    uuid references public.profiles(id) on delete cascade,
  to_comp    int  references public.companies(id) on delete cascade,
  amount     bigint not null check (amount > 0),
  memo       text not null default '',
  status     text not null default 'open',          -- open（未払い）/ paid / declined / canceled
  created_at timestamptz not null default now(),
  done_at    timestamptz
);
create index if not exists invoices_to_user_idx on public.invoices(to_user, status);
create index if not exists invoices_to_comp_idx on public.invoices(to_comp, status);
create index if not exists invoices_from_user_idx on public.invoices(from_user);
create index if not exists invoices_from_comp_idx on public.invoices(from_comp);
alter table public.invoices enable row level security;
revoke all on public.invoices from anon, authenticated;

-- 請求の1件を画面用に
create or replace function public._inv_json(i invoices) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', i.id, 'amount', i.amount, 'memo', i.memo, 'status', i.status,
    'fee', _xfer_fee(i.amount), 'at', _dlabel(i.created_at),
    'from_name', coalesce((select nickname from profiles where id = i.from_user), (select name from companies where id = i.from_comp)),
    'from_id',   coalesce((select account_no from profiles where id = i.from_user), (select _cfull(c) from companies c where c.id = i.from_comp)),
    'from_cid',  (select cid from companies where id = i.from_comp),
    'to_name',   coalesce((select nickname from profiles where id = i.to_user), (select name from companies where id = i.to_comp)),
    'to_id',     coalesce((select account_no from profiles where id = i.to_user), (select _cfull(c) from companies c where c.id = i.to_comp)),
    'to_cid',    (select cid from companies where id = i.to_comp))
$$;

-- 届いた請求（自分あて＋自分の会社あて）と、出した請求（自分から＋自分の会社から）
create or replace function public.invoice_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return jsonb_build_object(
    'incoming', (select coalesce(jsonb_agg(_inv_json(i) order by (i.status = 'open') desc, i.id desc), '[]'::jsonb) from (
        select * from invoices where to_user = u or to_comp in (select id from companies where owner = u)
         order by (status = 'open') desc, id desc limit 50) i),
    'outgoing', (select coalesce(jsonb_agg(_inv_json(i) order by (i.status = 'open') desc, i.id desc), '[]'::jsonb) from (
        select * from invoices where from_user = u or from_comp in (select id from companies where owner = u)
         order by (status = 'open') desc, id desc limit 50) i),
    'corps', (select coalesce(jsonb_agg(jsonb_build_object('cid', cid, 'name', name, 'balance', balance) order by id), '[]'::jsonb)
                from companies where owner = u and status = 'active'),
    'open_in', (select count(*) from invoices where status = 'open' and (to_user = u or to_comp in (select id from companies where owner = u))),
    'balance', _bal(u));
end $$;

-- 請求する。p_from_cid が空なら自分として、会社のIDなら会社として請求する
create or replace function public.invoice_create(p_from_cid text, p_to text, p_amount bigint, p_memo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; t record; fu uuid; fc int; fname text; fid text; owner_u uuid;
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000000000 then raise exception '請求する額は1 X以上にしてください'; end if;
  if coalesce(btrim(p_from_cid), '') = '' then
    fu := u; select nickname, account_no into fname, fid from profiles where id = u;
  else
    c := _my_corp(u, p_from_cid);
    if c.status <> 'active' then raise exception 'この会社はまだ活動していません'; end if;
    fc := c.id; fname := c.name; fid := _cfull(c);
  end if;
  select * into t from _find_id(p_to);
  if (fu is not null and t.rid = fu) or (fc is not null and t.rcomp = fc) then raise exception '自分には請求できません'; end if;
  if (select count(*) from invoices where status = 'open' and (from_user = fu or from_comp = fc)) >= 50 then
    raise exception '払われていない請求が多すぎます（50件まで）。いらない請求は取り消してください';
  end if;
  if exists (select 1 from invoices where status = 'open' and (from_user = fu or from_comp = fc)
               and (to_user = t.rid or to_comp = t.rcomp) and created_at > _now() - interval '1 minute') then
    raise exception '同じ相手への請求は1分あけてください';
  end if;
  insert into invoices(from_user, from_comp, to_user, to_comp, amount, memo, created_at)
  values (fu, fc, t.rid, t.rcomp, p_amount, left(btrim(coalesce(p_memo, '')), 100), _now());
  owner_u := coalesce(t.rid, (select owner from companies where id = t.rcomp));
  perform _notice(owner_u, format('【請求】%s（ID %s）から%s %s X の請求が届きました%s。役所の「請求」から払えます。',
    fname, fid, case when t.rcomp is not null then '会社「' || t.rname || '」あてに' else '' end, _fmt(p_amount),
    case when coalesce(btrim(p_memo), '') <> '' then '（' || left(btrim(p_memo), 100) || '）' else '' end));
  return invoice_list();
end $$;

-- 払う（自分あてなら自分のお金から、会社あてなら会社のお金から）
create or replace function public.invoice_pay(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); i invoices; to_id text; payer text; notify uuid;
begin
  select * into i from invoices where id = p_id for update;
  if not found or not (i.to_user = u or i.to_comp in (select id from companies where owner = u)) then raise exception '請求が見つかりません'; end if;
  if i.status <> 'open' then raise exception 'この請求はもう終わっています'; end if;
  to_id := coalesce((select account_no from profiles where id = i.from_user), (select cid from companies where id = i.from_comp and status = 'active'));
  if to_id is null then raise exception '請求した会社が活動していないので払えません'; end if;
  if i.to_user is not null then
    perform transfer_send(to_id, i.amount);
    payer := (select nickname from profiles where id = u) || ' さん';
  else
    perform corp_send((select cid from companies where id = i.to_comp), to_id, i.amount);
    payer := '会社「' || (select name from companies where id = i.to_comp) || '」';
  end if;
  update invoices set status = 'paid', done_at = _now() where id = i.id;
  notify := coalesce(i.from_user, (select owner from companies where id = i.from_comp));
  perform _notice(notify, format('【請求】%s が請求 #%s（%s X%s）を払いました。', payer, i.id, _fmt(i.amount),
    case when i.memo <> '' then '・' || i.memo else '' end));
  return invoice_list();
end $$;

-- 断る（請求された側）／取り消す（請求した側）
create or replace function public.invoice_close(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); i invoices; mine_to boolean; mine_from boolean;
begin
  select * into i from invoices where id = p_id for update;
  if not found then raise exception '請求が見つかりません'; end if;
  mine_to := i.to_user = u or i.to_comp in (select id from companies where owner = u);
  mine_from := i.from_user = u or i.from_comp in (select id from companies where owner = u);
  if not coalesce(mine_to, false) and not coalesce(mine_from, false) then raise exception '請求が見つかりません'; end if;
  if i.status <> 'open' then raise exception 'この請求はもう終わっています'; end if;
  if coalesce(mine_from, false) then
    update invoices set status = 'canceled', done_at = _now() where id = i.id;
    perform _notice(coalesce(i.to_user, (select owner from companies where id = i.to_comp)),
      format('【請求】請求 #%s（%s X）は取り消されました。', i.id, _fmt(i.amount)));
  else
    update invoices set status = 'declined', done_at = _now() where id = i.id;
    perform _notice(coalesce(i.from_user, (select owner from companies where id = i.from_comp)),
      format('【請求】請求 #%s（%s X）は断られました。', i.id, _fmt(i.amount)));
  end if;
  return invoice_list();
end $$;

-- ---------------------------------------------------------------------
-- 株（出資）：発行株数・株主・配当・社長の交代
--   株式会社は「株」、有限会社・合同会社は「口（出資）」として同じしくみで数える
--   許可されたとき、発行した株（はじめは100）を全部社長が持つ
-- ---------------------------------------------------------------------
alter table public.companies add column if not exists shares bigint not null default 100;
create table if not exists public.corp_holders (
  company_id int  not null references public.companies(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  shares     bigint not null check (shares > 0),
  primary key (company_id, user_id)
);
alter table public.corp_holders enable row level security;
revoke all on public.corp_holders from anon, authenticated;
-- 株主がいない活動中の会社は、社長が全部持っていることにする
insert into public.corp_holders(company_id, user_id, shares)
select c.id, c.owner, c.shares from public.companies c
 where c.status = 'active' and not exists (select 1 from public.corp_holders h where h.company_id = c.id);

create or replace function public._corp_holders(cid_int int) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'shares', h.shares,
           'pct', round(h.shares * 100.0 / greatest(c.shares, 1), 2)) order by h.shares desc, p.nickname), '[]'::jsonb)
    from corp_holders h join profiles p on p.id = h.user_id join companies c on c.id = h.company_id
   where h.company_id = cid_int
$$;

create or replace function public._add_shares(cid_int int, u uuid, n bigint) returns void
language plpgsql set search_path = public as $$
begin
  insert into corp_holders(company_id, user_id, shares) values (cid_int, u, n)
  on conflict (company_id, user_id) do update set shares = corp_holders.shares + excluded.shares;
  delete from corp_holders where company_id = cid_int and user_id = u and shares <= 0;
end $$;

-- 発行株数をふやす（ふえた分は社長のもの）／へらす（社長の持ち株から消す）
create or replace function public.corp_shares_change(p_cid text, p_delta bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; mine bigint;
begin
  if (select official from companies where cid = _cid_norm(p_cid)) then raise exception '国営の会社には株がありません'; end if;
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  if p_delta is null or p_delta = 0 then raise exception 'ふやす・へらす数を入れてください'; end if;
  if c.shares + p_delta < 1 or c.shares + p_delta > 1000000000 then raise exception '発行株数は1〜10億にしてください'; end if;
  if p_delta < 0 then
    select shares into mine from corp_holders where company_id = c.id and user_id = u;
    if coalesce(mine, 0) < -p_delta then raise exception 'へらせるのは社長が持っている分（%）までです', coalesce(mine, 0); end if;
    update corp_holders set shares = shares + p_delta where company_id = c.id and user_id = u;
    delete from corp_holders where company_id = c.id and shares <= 0;
  else
    perform _add_shares(c.id, u, p_delta);
  end if;
  update companies set shares = shares + p_delta where id = c.id;
  insert into corp_ledger(company_id, kind, amount, memo, balance_after)
  values (c.id, 'shares', 0, format('発行株数を %s → %s に', _fmt(c.shares), _fmt(c.shares + p_delta)), c.balance);
  return my_corps();
end $$;

-- 持っている株をほかの人にゆずる（代金は請求・送金で別にやりとりする）
create or replace function public.share_give(p_cid text, p_to text, p_shares bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; mine bigint; t record; me profiles;
begin
  if (select official from companies where cid = _cid_norm(p_cid)) then raise exception '国営の会社には株がありません'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません'; end if;
  select shares into mine from corp_holders where company_id = c.id and user_id = u for update;
  if p_shares is null or p_shares < 1 then raise exception 'ゆずる数を入れてください'; end if;
  if coalesce(mine, 0) < p_shares then raise exception 'ゆずれるのは持っている % までです', coalesce(mine, 0); end if;
  select * into t from _find_id(p_to);
  if t.rid is null then raise exception '株をゆずれるのはユーザーだけです'; end if;
  if t.rid = u then raise exception '自分にはゆずれません'; end if;
  select * into me from profiles where id = u;
  update corp_holders set shares = shares - p_shares where company_id = c.id and user_id = u;
  delete from corp_holders where company_id = c.id and shares <= 0;
  perform _add_shares(c.id, t.rid, p_shares);
  perform _notice(t.rid, format('【株】%s（ID %s）から「%s」の%s %s をゆずり受けました。', me.nickname, me.account_no, c.name,
                  case when c.form = '株式会社' then '株' else '出資' end, _fmt(p_shares)));
  return my_stocks();
end $$;

-- 自分の持ち株
create or replace function public.my_stocks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return jsonb_build_object('stocks', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'form', c.form, 'status', c.status,
           'shares', h.shares, 'total', c.shares, 'pct', round(h.shares * 100.0 / greatest(c.shares, 1), 2),
           'owner', (select nickname from profiles where id = c.owner), 'mine', c.owner = u,
           'dividend_total', (select coalesce(sum(payout), 0) from tx_log where user_id = u and game = 'dividend' and detail->>'company_id' = c.id::text))
           order by c.name), '[]'::jsonb)
         from corp_holders h join companies c on c.id = h.company_id where h.user_id = u and c.status in ('active', 'suspended')),
    'offers_in', (select coalesce(jsonb_agg(_offer_json(o) order by o.id desc), '[]'::jsonb) from share_offers o where o.to_user = u and o.status = 'open'),
    'offers_out', (select coalesce(jsonb_agg(_offer_json(o) order by o.id desc), '[]'::jsonb) from (
                    select * from share_offers where from_user = u order by (status = 'open') desc, id desc limit 20) o),
    'balance', _bal(u));
end $$;

-- 配当：会社のお金から、持ち株の数に合わせて株主に配る（端数は会社に残る）。もらった人の所得になる
create or replace function public.corp_dividend(p_cid text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; h record; amt bigint; total bigint := 0; n int := 0; r jsonb;
begin
  if (select official from companies where cid = _cid_norm(p_cid)) then raise exception '国営の会社は配当を出せません'; end if;
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  if p_amount is null or p_amount < 1 or p_amount > c.balance then raise exception '配当に使えるのは会社のお金 % X までです', c.balance; end if;
  for h in select * from corp_holders where company_id = c.id loop
    amt := floor(p_amount::numeric * h.shares / c.shares);
    if amt > 0 then
      perform _give(h.user_id, amt);
      perform _log(h.user_id, 'dividend', 0, amt, jsonb_build_object('company', c.name, 'company_id', c.id));
      perform _notice(h.user_id, format('【配当】「%s」から配当 %s X が入りました。', c.name, _fmt(amt)));
      total := total + amt; n := n + 1;
    end if;
  end loop;
  if total = 0 then raise exception '額が小さすぎて、だれにも配れません'; end if;
  perform _corp_move(c.id, -total, 'dividend', format('配当（%s人に合計 %s X）', n, _fmt(total)));
  r := my_corps();
  return r || jsonb_build_object('paid', total, 'people', n);
end $$;

-- 社長をほかの人に交代する
create or replace function public.corp_owner_set(p_cid text, p_to text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; t record; me profiles;
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  select * into t from _find_id(p_to);
  if t.rid is null then raise exception '社長にできるのはユーザーだけです'; end if;
  if t.rid = u then raise exception 'あなたがもう社長です'; end if;
  if (select count(*) from companies where owner = t.rid and status in ('pending', 'active', 'suspended')) >= 3 then
    raise exception 'その人はもう3社の社長です';
  end if;
  select * into me from profiles where id = u;
  update companies set owner = t.rid where id = c.id;
  delete from corp_members where company_id = c.id and user_id = t.rid;
  insert into corp_ledger(company_id, kind, amount, memo, balance_after)
  values (c.id, 'owner', 0, format('社長が %s さんから %s さんに交代', me.nickname, t.rname), c.balance);
  perform _notice(t.rid, format('【社長交代】%s さんから「%s」の社長をまかされました。会社のIDは %s になりました。仕事タブの「企業ページ」から運営できます。', me.nickname, c.name, c.cid || '-' || (select account_no from profiles where id = t.rid)));
  return my_corps();
end $$;

-- ---------------------------------------------------------------------
-- フレンドとタイムライン（TL）
-- ---------------------------------------------------------------------
create table if not exists public.friends (
  id         bigserial primary key,
  from_user  uuid not null references public.profiles(id) on delete cascade,
  to_user    uuid not null references public.profiles(id) on delete cascade,
  status     text not null default 'pending',     -- pending（申請中）/ ok（フレンド）
  created_at timestamptz not null default now()
);
create unique index if not exists friends_pair_idx on public.friends(least(from_user, to_user), greatest(from_user, to_user));
create index if not exists friends_to_idx on public.friends(to_user, status);
alter table public.friends enable row level security;
revoke all on public.friends from anon, authenticated;

create table if not exists public.posts (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists posts_time_idx on public.posts(id desc);
create index if not exists posts_user_idx on public.posts(user_id, id desc);
alter table public.posts enable row level security;
revoke all on public.posts from anon, authenticated;

create or replace function public._is_friend(a uuid, b uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from friends where status = 'ok' and least(from_user, to_user) = least(a, b) and greatest(from_user, to_user) = greatest(a, b))
$$;

create or replace function public.friend_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return jsonb_build_object(
    'friends', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'since', _dlabel(f.created_at)) order by p.nickname), '[]'::jsonb)
                  from friends f join profiles p on p.id = case when f.from_user = u then f.to_user else f.from_user end
                 where f.status = 'ok' and (f.from_user = u or f.to_user = u)),
    'incoming', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'at', _dlabel(f.created_at)) order by f.id desc), '[]'::jsonb)
                  from friends f join profiles p on p.id = f.from_user where f.status = 'pending' and f.to_user = u),
    'outgoing', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'at', _dlabel(f.created_at)) order by f.id desc), '[]'::jsonb)
                  from friends f join profiles p on p.id = f.to_user where f.status = 'pending' and f.from_user = u));
end $$;

-- フレンド申請（相手からも申請が来ていたら、そのままフレンドになる）
create or replace function public.friend_request(p_to text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t record; f friends; me profiles;
begin
  select * into t from _find_id(p_to);
  if t.rid is null then raise exception 'フレンドになれるのはユーザーだけです'; end if;
  if t.rid = u then raise exception '自分にはフレンド申請できません'; end if;
  select * into f from friends where least(from_user, to_user) = least(u, t.rid) and greatest(from_user, to_user) = greatest(u, t.rid);
  select * into me from profiles where id = u;
  if f.id is not null then
    if f.status = 'ok' then raise exception 'もうフレンドです'; end if;
    if f.from_user = u then raise exception 'もう申請しています。返事を待ちましょう'; end if;
    update friends set status = 'ok' where id = f.id;
    perform _notice(t.rid, format('【フレンド】%s（ID %s）とフレンドになりました。', me.nickname, me.account_no));
  else
    if (select count(*) from friends where from_user = u and status = 'pending') >= 30 then raise exception '返事待ちの申請が多すぎます（30件まで）'; end if;
    insert into friends(from_user, to_user, created_at) values (u, t.rid, _now());
    perform _notice(t.rid, format('【フレンド】%s（ID %s）からフレンド申請が来ました。情報タブの「フレンド」から返事できます。', me.nickname, me.account_no));
  end if;
  return friend_list();
end $$;

-- 申請に返事する（p_ok=false なら断る）
create or replace function public.friend_answer(p_from text, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t record; me profiles;
begin
  select * into t from _find_id(p_from);
  if t.rid is null then raise exception '申請が見つかりません'; end if;
  if not exists (select 1 from friends where from_user = t.rid and to_user = u and status = 'pending') then raise exception '申請が見つかりません'; end if;
  select * into me from profiles where id = u;
  if p_ok then
    update friends set status = 'ok' where from_user = t.rid and to_user = u;
    perform _notice(t.rid, format('【フレンド】%s（ID %s）がフレンド申請を受けました。', me.nickname, me.account_no));
  else
    delete from friends where from_user = t.rid and to_user = u;
  end if;
  return friend_list();
end $$;

-- フレンドをやめる・出した申請を取り消す
create or replace function public.friend_remove(p_uid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t record;
begin
  select * into t from _find_id(p_uid);
  delete from friends where least(from_user, to_user) = least(u, t.rid) and greatest(from_user, to_user) = greatest(u, t.rid)
    and (status = 'ok' or from_user = u);
  return friend_list();
end $$;

-- TL：p_scope = 'friends'（自分とフレンド）か 'all'（みんな）。p_before より前の投稿を30件
create or replace function public.tl_list(p_scope text, p_before bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'body', z.body, 'at', _dlabel(z.created_at),
            'ts', floor(extract(epoch from z.created_at) * 1000), 'nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id),
            'mine', z.user_id = u, 'friend', _is_friend(u, z.user_id),
            'asked', exists (select 1 from friends f where f.from_user = u and f.to_user = z.user_id and f.status = 'pending'))
            order by z.id desc), '[]'::jsonb)
    from (select * from posts
           where (p_before is null or id < p_before)
             and (coalesce(p_scope, 'all') = 'all' or user_id = u or _is_friend(u, user_id))
           order by id desc limit 30) z join profiles p on p.id = z.user_id);
end $$;

create or replace function public.tl_post(p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); b text := btrim(coalesce(p_body, ''));
begin
  if char_length(b) < 1 then raise exception '何か書いてください'; end if;
  if char_length(b) > 140 then raise exception '140文字までです'; end if;
  if exists (select 1 from posts where user_id = u and created_at > _now() - interval '10 seconds') then
    raise exception '連続の投稿は10秒あけてください';
  end if;
  if (select count(*) from posts where user_id = u and created_at > _now() - interval '1 day') >= 100 then
    raise exception '投稿は1日100件までです';
  end if;
  insert into posts(user_id, body, created_at) values (u, b, _now());
  -- TLは256通まで。あふれたら古い順に消す
  delete from posts where id <= (select id from posts order by id desc offset 256 limit 1);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.tl_delete(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  delete from posts where id = p_id and (user_id = u or _is_staff(u));
  if not found then raise exception '消せる投稿が見つかりません'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 通貨の取引所（AiliNaX ⇄ Cièlani-Alpićsk）
--   Cièlani-Alpićsk（CA）：Cièlani-Nièpha（CN・風の芽公式サーバーの通貨）と同じ価値の、サイトの中で使う通貨
--   値段は「1 X = 何 CA」（小数第4位まで）。買い注文＝CAを払ってXを買う、売り注文＝Xを売ってCAをもらう
--   約定は先に出ていた注文の値段。動くCAは、買い注文ごとに約定の合計を切り上げた整数（端数で得をしないように）
--   注文中のお金は預かる（買い：数量×値段を切り上げたCA、売り：数量のX）。取り消すと戻る
--   取引所は「証券」の会社が開く（国営の風の芽証券取引所のほか、私営の取引所も開ける）。取引所ごとに板（注文の一覧）がある
--   取引所ごとに、取り扱う通貨（いまは AiliNaX ⇄ Cièlani-Alpićsk だけ）と手数料（%）を決める
--   手数料：買った人は受け取るXから、売った人は受け取るCAから引かれ、その取引所の会社に入る
--   取引所の会社が休業していると注文できない（取り消しはできる）。廃業・倒産すると、出ている注文は全部取り消して返す
--   CN ⇄ CA は運営者が手で交換（1万単位）：交換申請 → 管理者が処理
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists ca bigint not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_ca_chk') then
    alter table public.profiles add constraint profiles_ca_chk check (ca >= 0);
  end if;
end $$;
alter table public.companies add column if not exists ca bigint not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'companies_ca_chk') then
    alter table public.companies add constraint companies_ca_chk check (ca >= 0);
  end if;
end $$;

alter table public.companies add column if not exists fx_fee numeric not null default 0.1;       -- 取引所の手数料（%）
alter table public.companies add column if not exists fx_pairs text[] not null default '{}';    -- 取り扱う通貨（'X/CA'）

create table if not exists public.fx_orders (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  side        text not null check (side in ('buy', 'sell')),   -- buy：Xを買う（CAを払う）／sell：Xを売る
  price       numeric(20,4) not null check (price > 0),         -- 1 X あたりの CA
  qty         bigint not null check (qty > 0),                  -- X の数
  remain      bigint not null check (remain >= 0),
  locked      bigint not null default 0,                        -- 買い：まだ預かっているCA
  spent_exact numeric not null default 0,                       -- 買い：約定したCAの正確な合計
  spent       bigint not null default 0,                        -- 買い：実際に払ったCA（spent_exact の切り上げ）
  status      text not null default 'open',                     -- open / done / canceled
  created_at  timestamptz not null default now()
);
create table if not exists public.fx_trades (
  id         bigserial primary key,
  buy_order  bigint not null,
  sell_order bigint not null,
  buyer      uuid not null references public.profiles(id) on delete cascade,
  seller     uuid not null references public.profiles(id) on delete cascade,
  price      numeric(20,4) not null,
  qty        bigint not null,
  value      bigint not null default 0,     -- 動いたCA
  fee_x      bigint not null default 0,     -- 買った人から取った手数料（X）
  fee_ca     bigint not null default 0,     -- 売った人から取った手数料（CA）
  created_at timestamptz not null default now()
);
alter table public.fx_orders add column if not exists exch_id int references public.companies(id) on delete cascade;
alter table public.fx_trades add column if not exists exch_id int references public.companies(id) on delete cascade;
-- 前の形（値段が整数・預かりの列なし）からの切りかえ（1回だけ）
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'fx_orders' and column_name = 'locked') then
    alter table public.fx_orders add column locked bigint not null default 0;
    alter table public.fx_orders add column spent_exact numeric not null default 0;
    alter table public.fx_orders add column spent bigint not null default 0;
    update public.fx_orders set locked = remain * price where side = 'buy' and status = 'open';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'fx_trades' and column_name = 'value') then
    alter table public.fx_trades add column value bigint not null default 0;
    alter table public.fx_trades add column fee_x bigint not null default 0;
    alter table public.fx_trades add column fee_ca bigint not null default 0;
    update public.fx_trades set value = (price * qty)::bigint;
  end if;
end $$;
alter table public.fx_orders alter column price type numeric(20,4);
alter table public.fx_trades alter column price type numeric(20,4);
-- 国営の取引所：株式会社ではなく「国営」（公式マーク）。AiliNaX ⇄ CA を扱う。前からある注文・取引はこの取引所のもの
update public.companies set form = '国営', official = true,
       name = regexp_replace(regexp_replace(name, '^株式会社', ''), '株式会社$', ''),
       fx_pairs = case when 'X/CA' = any(fx_pairs) then fx_pairs else fx_pairs || '{X/CA}'::text[] end,
       fx_fee = coalesce((select value::numeric from public.app_settings where key = 'fx_fee_pct'), fx_fee)
 where cid = (select value from public.app_settings where key = 'exchange_cid') and not official;
delete from public.corp_holders where company_id in (select id from public.companies where official);
update public.fx_orders set exch_id = (select id from public.companies where cid = (select value from public.app_settings where key = 'exchange_cid')) where exch_id is null;
update public.fx_trades set exch_id = (select id from public.companies where cid = (select value from public.app_settings where key = 'exchange_cid')) where exch_id is null;
create index if not exists fx_orders_book2_idx on public.fx_orders(exch_id, side, status, price, id);
create index if not exists fx_orders_book_idx on public.fx_orders(side, status, price, id);
create index if not exists fx_orders_user_idx on public.fx_orders(user_id, status);
create index if not exists fx_trades_time_idx on public.fx_trades(created_at);
create table if not exists public.fx_requests (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('in', 'out')),     -- in：CN→CA ／ out：CA→CN
  amount     bigint not null check (amount > 0),
  contact    text not null default '',
  status     text not null default 'pending',                 -- pending / done / rejected
  note       text,
  created_at timestamptz not null default now(),
  done_at    timestamptz
);
alter table public.fx_orders enable row level security;
alter table public.fx_trades enable row level security;
alter table public.fx_requests enable row level security;
revoke all on public.fx_orders, public.fx_trades, public.fx_requests from anon, authenticated;

-- 国営の取引所の手数料（%）
create or replace function public._fx_fee_pct() returns numeric
language sql stable set search_path = public as $$
  select coalesce((select fx_fee from companies where cid = (select value from app_settings where key = 'exchange_cid')), 0.1)
$$;

-- 取引所の一覧に出す形
create or replace function public._fx_exch_json(c companies) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('cid', c.cid, 'name', c.name, 'official', c.official, 'open', c.status = 'active',
    'fee_pct', c.fx_fee, 'pairs', c.fx_pairs,
    'last', (select price from fx_trades where exch_id = c.id order by id desc limit 1),
    'vol', (select coalesce(sum(qty), 0) from fx_trades where exch_id = c.id and created_at > _now() - interval '1 day'))
$$;

-- 相場（だれでも見られる部分。だれが取引したかは出さない）
create or replace function public._fx_market(eid int) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'last', (select price from fx_trades where exch_id = eid order by id desc limit 1),
    'prev', (select price from fx_trades where exch_id = eid and created_at <= _now() - interval '1 day' order by id desc limit 1),
    'first', (select price from fx_trades where exch_id = eid and created_at > _now() - interval '1 day' order by id limit 1),
    'bid', (select max(price) from fx_orders where exch_id = eid and side = 'buy' and status = 'open'),
    'ask', (select min(price) from fx_orders where exch_id = eid and side = 'sell' and status = 'open'),
    'vol', (select coalesce(sum(qty), 0) from fx_trades where exch_id = eid and created_at > _now() - interval '1 day'),
    'bids', (select coalesce(jsonb_agg(jsonb_build_object('price', price, 'qty', q) order by price desc), '[]'::jsonb) from (
              select price, sum(remain) q from fx_orders where exch_id = eid and side = 'buy' and status = 'open' group by price order by price desc limit 8) z),
    'asks', (select coalesce(jsonb_agg(jsonb_build_object('price', price, 'qty', q) order by price), '[]'::jsonb) from (
              select price, sum(remain) q from fx_orders where exch_id = eid and side = 'sell' and status = 'open' group by price order by price limit 8) z),
    'trades', (select coalesce(jsonb_agg(jsonb_build_object('price', price, 'qty', qty, 'ts', _kb_ms(created_at)) order by id desc), '[]'::jsonb) from (
              select * from fx_trades where exch_id = eid order by id desc limit 20) z),
    'chart', (select coalesce(jsonb_agg(jsonb_build_object('price', price, 'ts', _kb_ms(created_at)) order by id), '[]'::jsonb) from (
              select * from fx_trades where exch_id = eid order by id desc limit 100) z),
    'fee_pct', (select fx_fee from companies where id = eid),
    'exchange', (select _fx_exch_json(c) from companies c where c.id = eid))
$$;

-- 取引所の一覧（AiliNaX ⇄ CA を扱っている「証券」の会社。国営が先）
create or replace function public._fx_exchanges() returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(_fx_exch_json(c) order by c.official desc, c.name), '[]'::jsonb)
    from companies c where c.kind = '証券' and c.status in ('active', 'suspended') and 'X/CA' = any(c.fx_pairs)
$$;

-- 取引所をえらぶ（ID か、なければ国営）
create or replace function public._fx_pick(p_exch text) returns companies
language plpgsql stable set search_path = public as $$
declare c companies;
begin
  if coalesce(btrim(p_exch), '') <> '' then
    select * into c from companies where cid = _cid_norm(p_exch) and kind = '証券' and status in ('active', 'suspended') and 'X/CA' = any(fx_pairs);
    if found then return c; end if;
  end if;
  select * into c from companies where kind = '証券' and status in ('active', 'suspended') and 'X/CA' = any(fx_pairs)
   order by official desc, (cid = (select value from app_settings where key = 'exchange_cid')) desc, id limit 1;
  return c;
end $$;

-- 情報タブの「相場」：取引所ごとの値段
drop function if exists public.market_info();
create or replace function public.market_info() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _me();
  return jsonb_build_object('exchanges', _fx_exchanges(),
    'fx', (select _fx_market(c.id) from _fx_pick(null) c where c.id is not null), 'stocks', '[]'::jsonb);
end $$;

-- 取引所の画面（相場＋自分の残高・注文・交換申請）
drop function if exists public.fx_state();
create or replace function public.fx_state(p_exch text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); xc companies := _fx_pick(p_exch);
begin
  return jsonb_build_object('exchanges', _fx_exchanges(), 'exch', case when xc.id is null then null else xc.cid end,
    'market', case when xc.id is null then null else _fx_market(xc.id) end,
    'ca', (select ca from profiles where id = u), 'balance', _bal(u),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'side', side, 'price', price, 'qty', qty, 'remain', remain,
                 'spent', spent, 'status', status, 'at', _dlabel(created_at),
                 'exch', (select name from companies where companies.id = z.exch_id)) order by (status = 'open') desc, id desc), '[]'::jsonb) from (
               select * from fx_orders where user_id = u order by (status = 'open') desc, id desc limit 30) z),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'amount', amount, 'contact', contact,
                 'status', status, 'note', note, 'at', _dlabel(created_at)) order by id desc), '[]'::jsonb) from (
               select * from fx_requests where user_id = u order by id desc limit 20) z));
end $$;

-- 注文する
drop function if exists public.fx_order(text, bigint, bigint);
drop function if exists public.fx_order(text, numeric, bigint);
create or replace function public.fx_order(p_exch text, p_side text, p_price numeric, p_qty bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); o fx_orders; m fx_orders; bo fx_orders; so fx_orders; xc companies; me profiles;
  q bigint; v bigint; ex numeric; fx bigint; fc bigint; lockamt bigint; okday timestamptz;
  pct numeric; tot_x bigint := 0; tot_c bigint := 0;
begin
  if p_side not in ('buy', 'sell') then raise exception '買いか売りをえらんでください'; end if;
  if p_price is null or p_price <= 0 or p_price > 1000000000 then raise exception '値段は0より大きく、10億 CA までにしてください'; end if;
  if p_price <> round(p_price, 4) then raise exception '値段は小数第4位までです'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 1000000000 then raise exception '数量は1〜10億 X にしてください'; end if;
  xc := _fx_pick(p_exch);
  if xc.id is null or (coalesce(btrim(p_exch), '') <> '' and xc.cid <> _cid_norm(p_exch)) then raise exception 'その取引所は見つかりません'; end if;
  if xc.status <> 'active' then raise exception '取引所（%）がいま営業していないので、注文できません', xc.name; end if;
  pct := xc.fx_fee;
  select * into me from profiles where id = u for update;
  okday := me.created_at + interval '7 days';
  if _now() < okday then raise exception '登録から7日たつまで取引所は使えません（%から）', _dlabel(okday); end if;
  if (select count(*) from fx_orders where user_id = u and status = 'open') >= 30 then raise exception '出せる注文は30件までです'; end if;
  if p_side = 'buy' then
    lockamt := ceil(p_price * p_qty)::bigint;
    update profiles set ca = ca - lockamt where id = u and ca >= lockamt;
    if not found then raise exception 'Cièlani-Alpićsk が足りません（% CA 必要です）', lockamt; end if;
  else
    lockamt := 0;
    update profiles set balance = balance - p_qty where id = u and balance >= p_qty;
    if not found then raise exception 'AiliNaX が足りません'; end if;
  end if;
  insert into fx_orders(exch_id, user_id, side, price, qty, remain, locked, created_at)
  values (xc.id, u, p_side, p_price, p_qty, p_qty, lockamt, _now()) returning * into o;
  -- 反対側の注文と合わせる（値段の良い順・先に出た順。自分の注文とは合わせない）
  loop
    exit when o.remain = 0;
    if o.side = 'buy' then
      select * into m from fx_orders where exch_id = xc.id and side = 'sell' and status = 'open' and price <= o.price and user_id <> u
       order by price, id limit 1 for update;
    else
      select * into m from fx_orders where exch_id = xc.id and side = 'buy' and status = 'open' and price >= o.price and user_id <> u
       order by price desc, id limit 1 for update;
    end if;
    exit when not found;
    q := least(o.remain, m.remain);
    if o.side = 'buy' then bo := o; so := m; else bo := m; so := o; end if;
    ex := bo.spent_exact + q * m.price;            -- 値段は先に出ていた注文（m）の値段
    v := ceil(ex)::bigint - bo.spent;              -- このとき動くCA（買い注文ごとに合計を切り上げ）
    if v > bo.locked then raise exception '預かりが足りません（内部エラー）'; end if;
    update fx_orders set remain = remain - q, spent_exact = ex, spent = spent + v, locked = locked - v,
           status = case when remain - q = 0 then 'done' else status end
     where id = bo.id returning * into bo;
    update fx_orders set remain = remain - q, status = case when remain - q = 0 then 'done' else status end
     where id = so.id returning * into so;
    fx := floor(q * pct / 100); fc := floor(v * pct / 100);
    perform _give(bo.user_id, q - fx);                                   -- 買った人に X（手数料を引く）
    update profiles set ca = ca + (v - fc) where id = so.user_id;       -- 売った人に CA（手数料を引く）
    insert into fx_trades(exch_id, buy_order, sell_order, buyer, seller, price, qty, value, fee_x, fee_ca, created_at)
    values (xc.id, bo.id, so.id, bo.user_id, so.user_id, m.price, q, v, fx, fc, _now());
    tot_x := tot_x + fx; tot_c := tot_c + fc;
    if bo.remain = 0 and bo.locked > 0 then                              -- 買い終わったら、あまった預かりを返す
      update profiles set ca = ca + bo.locked where id = bo.user_id;
      update fx_orders set locked = 0 where id = bo.id returning * into bo;
    end if;
    if o.side = 'buy' then o := bo; else o := so; end if;
  end loop;
  if tot_x > 0 then perform _corp_move(xc.id, tot_x, 'fx_fee', format('取引の手数料 %s X', _fmt(tot_x))); end if;
  if tot_c > 0 then
    update companies set ca = ca + tot_c where id = xc.id;
    insert into corp_ledger(company_id, kind, amount, memo, balance_after)
    values (xc.id, 'fx_fee', 0, format('取引の手数料 %s CA', _fmt(tot_c)), (select balance from companies where id = xc.id));
  end if;
  return fx_state(xc.cid);
end $$;

-- 注文を1つ取り消して、預けたお金を返す（中で使う）
create or replace function public._fx_cancel_order(oid bigint) returns void
language plpgsql set search_path = public as $$
declare o fx_orders;
begin
  select * into o from fx_orders where id = oid and status = 'open' for update;
  if not found then return; end if;
  update fx_orders set status = 'canceled', locked = 0 where id = o.id;
  if o.side = 'buy' then update profiles set ca = ca + o.locked where id = o.user_id;
  else update profiles set balance = balance + o.remain where id = o.user_id; end if;
end $$;

-- 注文を取り消す（残りの預けたお金を返す）
create or replace function public.fx_cancel(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); o fx_orders;
begin
  select * into o from fx_orders where id = p_id and user_id = u and status = 'open' for update;
  if not found then raise exception '取り消せる注文が見つかりません'; end if;
  perform _fx_cancel_order(o.id);
  return fx_state((select cid from companies where id = o.exch_id));
end $$;

-- 管理者：国営の取引所の手数料（%）を決める
create or replace function public.admin_fx_fee(p_pct numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  if not _is_admin(u) then raise exception '管理者だけが使えます'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 10 then raise exception '手数料は0〜10%%にしてください'; end if;
  update companies set fx_fee = round(p_pct, 4) where cid = (select value from app_settings where key = 'exchange_cid');
  return admin_state();
end $$;

-- 取引所の設定（証券の会社）：取り扱う通貨と手数料。取り扱いをやめると、その板の注文は取り消して返す
create or replace function public.exch_settings(p_cid text, p_pairs text[], p_fee numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; r record; pairs text[] := coalesce(p_pairs, '{}');
begin
  c := _my_corp(u, p_cid);
  if c.kind <> '証券' then raise exception '取引所を開けるのは証券の会社だけです'; end if;
  if exists (select 1 from unnest(pairs) x where x not in ('X/CA')) then raise exception '取り扱える通貨は、いまは AiliNaX ⇄ Cièlani-Alpićsk だけです'; end if;
  if p_fee is null or p_fee < 0 or p_fee > 10 then raise exception '手数料は0〜10%%にしてください'; end if;
  if not ('X/CA' = any(pairs)) then
    for r in select id from fx_orders where exch_id = c.id and status = 'open' loop perform _fx_cancel_order(r.id); end loop;
  end if;
  update companies set fx_pairs = pairs, fx_fee = round(p_fee, 4) where id = c.id;
  return my_corps();
end $$;

-- 会社の Cièlani-Alpićsk を社長に移す
create or replace function public.corp_ca_withdraw(p_cid text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません'; end if;
  if p_amount is null or p_amount < 1 or p_amount > c.ca then raise exception '移せるのは % CA までです', c.ca; end if;
  update companies set ca = ca - p_amount where id = c.id;
  update profiles set ca = ca + p_amount where id = u;
  insert into corp_ledger(company_id, kind, amount, memo, balance_after)
  values (c.id, 'ca_out', 0, format('Cièlani-Alpićsk %s CA を社長に移した', _fmt(p_amount)), c.balance);
  return my_corps();
end $$;

-- Cièlani-Nièpha との交換申請（1万単位。運営者が手で処理）
create or replace function public.fx_request(p_kind text, p_amount bigint, p_contact text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); me profiles;
begin
  if p_kind not in ('in', 'out') then raise exception '交換の向きをえらんでください'; end if;
  if p_amount is null or p_amount < 10000 or p_amount % 10000 <> 0 or p_amount > 10000000000 then raise exception '交換は1万単位です'; end if;
  if char_length(btrim(coalesce(p_contact, ''))) < 2 then raise exception '連絡先（Discordなど）を書いてください'; end if;
  if (select count(*) from fx_requests where user_id = u and status = 'pending') >= 5 then raise exception '処理待ちの申請は5件までです'; end if;
  select * into me from profiles where id = u for update;
  if p_kind = 'out' then
    update profiles set ca = ca - p_amount where id = u and ca >= p_amount;
    if not found then raise exception 'Cièlani-Alpićsk が足りません'; end if;
  end if;
  insert into fx_requests(user_id, kind, amount, contact, created_at) values (u, p_kind, p_amount, left(btrim(p_contact), 120), _now());
  return fx_state();
end $$;

-- 申請を取り消す（処理前だけ）
create or replace function public.fx_request_cancel(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r fx_requests;
begin
  select * into r from fx_requests where id = p_id and user_id = u and status = 'pending' for update;
  if not found then raise exception '取り消せる申請が見つかりません'; end if;
  update fx_requests set status = 'rejected', note = '本人が取り消し', done_at = _now() where id = r.id;
  if r.kind = 'out' then update profiles set ca = ca + r.amount where id = u; end if;
  return fx_state();
end $$;

-- 管理者：交換申請を処理する（in を通すと CA をふやす。out を通すと預かった CA を消す。断ると out は CA を返す）
create or replace function public.admin_fx_decide(p_id bigint, p_ok boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r fx_requests;
begin
  if not _is_staff(u) then raise exception '管理者だけが使えます'; end if;
  select * into r from fx_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception '処理待ちの申請が見つかりません'; end if;
  if r.user_id = u and _role(u) <> 'admin' then raise exception '自分の申請は処理できません'; end if;
  update fx_requests set status = case when p_ok then 'done' else 'rejected' end, note = left(coalesce(p_note, ''), 200), done_at = _now() where id = r.id;
  -- in を通す：国が持っている Cièlani-Alpićsk（380億）から渡す／out を通す：預かったCAを国にもどす
  if p_ok and r.kind = 'in' then
    update treasury set ca_balance = ca_balance - r.amount where id = 1 and ca_balance >= r.amount;
    if not found then raise exception '国が持っている Cièlani-Alpićsk が足りません'; end if;
    update profiles set ca = ca + r.amount where id = r.user_id;
  end if;
  if p_ok and r.kind = 'out' then update treasury set ca_balance = ca_balance + r.amount where id = 1; end if;
  if not p_ok and r.kind = 'out' then update profiles set ca = ca + r.amount where id = r.user_id; end if;
  perform _notice(r.user_id, format('【交換】%s %s の申請（#%s）は%s。%s',
    case r.kind when 'in' then 'Cièlani-Nièpha → Cièlani-Alpićsk' else 'Cièlani-Alpićsk → Cièlani-Nièpha' end, _fmt(r.amount), r.id,
    case when p_ok then 'できあがりました' else '断られました' end,
    case when coalesce(p_note, '') <> '' then 'メモ：' || p_note else '' end));
  return admin_state();
end $$;

-- ---------------------------------------------------------------------
-- Cièlani-Alpićsk の発行：380億 CA を1回だけ（これ以上は発行しない）
--   国（treasury.ca_balance）が持っていて、Cièlani-Nièpha との交換で出し入れする
-- ---------------------------------------------------------------------
alter table public.treasury add column if not exists ca_balance bigint not null default 0;
alter table public.treasury add column if not exists ca_issued  bigint not null default 0;
update public.treasury set ca_balance = ca_balance + 38000000000, ca_issued = 38000000000 where id = 1 and ca_issued = 0;

-- ---------------------------------------------------------------------
-- 会社の休業・廃業・倒産
--   休業：社長が休む（再開できる）。商品は買えない・送金や請求は受けられない・求人は出ない・銀行は預けられない（引き出しはOK）
--   廃業：会社をたたむ。払うべきもの（渡していない注文の代金・銀行の払えていない利息・役所の賠償金）を全部払えるときだけ
--   倒産：払うべきものより会社のお金が少ないとき。会社のお金を払うべき額の割合で分けて返す。株は消える
--   どちらも：銀行の預金は全部返す・請求は取り消し・社員は解散・残ったお金は株主に持ち株の割合で分ける（端数は社長）
--             会社の Cièlani-Alpićsk は社長へ
-- ---------------------------------------------------------------------
create or replace function public._cstat(st text) returns text
language sql immutable as $$
  select case st when 'pending' then '審査中' when 'active' then '営業中' when 'suspended' then '休業中'
                 when 'closed' then '廃業' when 'bankrupt' then '倒産' when 'rejected' then '却下' else st end
$$;

create or replace function public._corp_close(cid_int int, how text, why text) returns jsonb
language plpgsql set search_path = public as $$
declare c companies; r record; owed_orders bigint; owed_int bigint; owed_court bigint; claims bigint;
  ratio numeric; amt bigint; rest bigint; total bigint := 0; label text; refunded bigint := 0; deposits bigint := 0; holders int := 0;
begin
  select * into c from companies where id = cid_int for update;
  if not found or c.status not in ('active', 'suspended') then raise exception 'この会社はもう活動していません'; end if;
  label := case when how = 'closed' then '廃業' else '倒産' end;
  if c.kind = '銀行' then
    perform _bank_accrue_all(c.id);
    select * into c from companies where id = cid_int;
  end if;
  owed_orders := coalesce((select sum(price) from corp_orders where company_id = c.id and status = 'paid'), 0);
  owed_int    := coalesce((select sum(floor(unpaid))::bigint from bank_accounts where company_id = c.id), 0);
  owed_court  := coalesce((select sum(comp_unpaid) from court_cases where defendant_comp = c.id and comp_unpaid > 0), 0);
  claims := owed_orders + owed_int + owed_court;
  if how = 'closed' and c.balance < claims then
    raise exception '会社のお金（% X）が、払うべきもの（% X）より少ないので廃業できません。倒産の手続きをしてください', c.balance, claims;
  end if;
  if how = 'bankrupt_self' and c.balance >= claims then
    raise exception 'お金が足りているので、倒産ではなく廃業にしてください';
  end if;
  ratio := case when claims = 0 then 1 else least(1, c.balance::numeric / claims) end;
  -- 渡していない注文の代金を返す
  for r in select * from corp_orders where company_id = c.id and status = 'paid' order by id loop
    amt := floor(r.price * ratio);
    if amt > 0 then
      perform _corp_move(c.id, -amt, 'refund', format('注文 #%s の返金（%s）', r.id, label));
      perform _give(r.buyer, amt);
      perform _log(r.buyer, 'order_refund', 0, amt, jsonb_build_object('company', c.name, 'order', r.id));
    end if;
    refunded := refunded + amt;
    update corp_orders set status = 'refunded', done_at = _now() where id = r.id;
    perform _notice(r.buyer, format('【%s】「%s」が%sしたため、注文 #%s（%s X）の代金のうち %s X を返しました。',
                    label, c.name, label, r.id, _fmt(r.price), _fmt(amt)));
  end loop;
  -- 銀行：払えていない利息（割合で）と、預金を全部返す
  for r in select * from bank_accounts where company_id = c.id and status = 'active' loop
    amt := floor(floor(r.unpaid) * ratio);
    if amt > 0 then
      perform _corp_move(c.id, -amt, 'interest', '預金の利息（' || label || '）');
      update profiles set balance = balance + amt where id = r.user_id;
      perform _log(r.user_id, 'interest', 0, amt, jsonb_build_object('bank', c.name));
    end if;
    if r.balance > 0 then
      update profiles set balance = balance + r.balance where id = r.user_id;
      perform _log(r.user_id, 'withdraw', 0, r.balance, jsonb_build_object('bank', c.name, 'closed', true));
    end if;
    deposits := deposits + r.balance;
    perform _notice(r.user_id, format('【%s】銀行「%s」が%sしたため、預金 %s X をあなたに返しました。', label, c.name, label, _fmt(r.balance)));
  end loop;
  delete from bank_accounts where company_id = c.id;
  -- 借入の申込は取り消し、貸している分は帳消し（返さなくてよくなる）
  update loans set status = 'canceled', closed_at = _now() where company_id = c.id and status = 'pending';
  for r in select * from loans where company_id = c.id and status = 'active' loop
    update loans set status = 'forgiven', closed_at = _now() where id = r.id;
    perform _notice(r.user_id, format('【借入】「%s」が%sしたため、借入 #%s の残り %s X は返さなくてよくなりました。', c.name, label, r.id, _fmt(_loan_owed(r.id))));
  end loop;
  -- 役所の賠償金（割合で。残りはなくなる）
  for r in select * from court_cases where defendant_comp = c.id and comp_unpaid > 0 loop
    amt := floor(r.comp_unpaid * ratio);
    if amt > 0 then
      perform _corp_move(c.id, -amt, 'court', format('訴え #%s の賠償金（%s）', r.id, label));
      perform _give(r.plaintiff, amt);
      perform _log(r.plaintiff, 'court_comp', 0, amt, jsonb_build_object('case', r.id));
    end if;
    update court_cases set comp_paid = comp_paid + amt, comp_unpaid = 0 where id = r.id;
    perform _notice(r.plaintiff, format('【訴え #%s】「%s」が%sしたため、賠償金のうち %s X を受け取りました（残りはなくなりました）。', r.id, c.name, label, _fmt(amt)));
  end loop;
  -- 取引所なら、出ている注文を全部取り消して返す
  for r in select id from fx_orders where exch_id = c.id and status = 'open' loop perform _fx_cancel_order(r.id); end loop;
  -- 請求・求人・社員
  update invoices set status = 'canceled', done_at = _now() where status = 'open' and (from_comp = c.id or to_comp = c.id);
  update corp_jobs set active = false where company_id = c.id;
  update corp_applies set status = 'declined' where status = 'waiting' and job_id in (select id from corp_jobs where company_id = c.id);
  for r in select user_id from corp_members where company_id = c.id loop
    perform _notice(r.user_id, format('【%s】勤め先の「%s」が%sしました。', label, c.name, label));
  end loop;
  delete from corp_members where company_id = c.id;
  -- 残ったお金を株主に（持ち株の割合。端数は社長）
  select balance into rest from companies where id = c.id;
  if rest > 0 then
    for r in select * from corp_holders where company_id = c.id loop
      amt := floor(rest::numeric * r.shares / greatest(c.shares, 1));
      if amt > 0 then
        perform _give(r.user_id, amt);
        perform _log(r.user_id, 'liquidation', 0, amt, jsonb_build_object('company', c.name));
        perform _notice(r.user_id, format('【%s】「%s」の残ったお金から、持ち株の割合で %s X を受け取りました。', label, c.name, _fmt(amt)));
        total := total + amt; holders := holders + 1;
      end if;
    end loop;
    if rest - total > 0 then
      perform _give(c.owner, rest - total);
      perform _log(c.owner, 'liquidation', 0, rest - total, jsonb_build_object('company', c.name));
    end if;
    perform _corp_move(c.id, -rest, 'liquidation', '残ったお金を株主に分配（' || label || '）');
  end if;
  if c.ca > 0 then
    update profiles set ca = ca + c.ca where id = c.owner;
    update companies set ca = 0 where id = c.id;
  end if;
  for r in select user_id from corp_holders where company_id = c.id and user_id <> c.owner loop
    perform _notice(r.user_id, format('【%s】「%s」が%sしました。持っていた株はなくなりました。', label, c.name, label));
  end loop;
  delete from corp_holders where company_id = c.id;
  delete from corp_pins where company_id = c.id;
  update share_offers set status = 'canceled', done_at = _now() where company_id = c.id and status = 'open';
  update companies set status = case when how = 'closed' then 'closed' else 'bankrupt' end,
         reason = left(coalesce(why, ''), 300), closed_at = _now(), court_lock = false
   where id = c.id;
  perform _notice(c.owner, format('【%s】「%s」を%sしました。%s', label, c.name, label,
                  case when coalesce(why, '') <> '' then '（' || why || '）' else '' end));
  return jsonb_build_object('refunded', refunded, 'deposits', deposits, 'distributed', rest, 'holders', holders, 'ratio', ratio);
end $$;

-- 社長：休業する・再開する
create or replace function public.corp_suspend(p_cid text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if p_on then
    if c.status <> 'active' then raise exception '営業中の会社だけ休業できます'; end if;
    update companies set status = 'suspended' where id = c.id;
    for c in select * from companies where id = c.id loop end loop;
  else
    if c.status <> 'suspended' then raise exception '休業中ではありません'; end if;
    if c.court_lock then raise exception '役所の命令で休業中なので、自分では再開できません'; end if;
    update companies set status = 'active' where id = c.id;
  end if;
  insert into corp_ledger(company_id, kind, amount, memo, balance_after)
  values (c.id, 'status', 0, case when p_on then '休業した' else '営業を再開した' end, c.balance);
  return my_corps();
end $$;

-- 社長：廃業する（p_kind = 'close'）・倒産する（p_kind = 'bankrupt'）
create or replace function public.corp_close(p_cid text, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; r jsonb;
begin
  c := _my_corp(u, p_cid);
  if p_kind not in ('close', 'bankrupt') then raise exception '廃業か倒産をえらんでください'; end if;
  if c.cid = (select value from app_settings where key = 'exchange_cid') and _role(u) <> 'admin' then
    raise exception '取引所の会社は、管理者しかたためません';
  end if;
  r := _corp_close(c.id, case when p_kind = 'close' then 'closed' else 'bankrupt_self' end, null);
  return my_corps() || jsonb_build_object('result', r);
end $$;

-- 管理者：会社を休業させる・再開させる・倒産させる
create or replace function public.admin_corp_action(p_cid text, p_action text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  if not _is_admin(u) then raise exception '管理者だけが使えます'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended') for update;
  if not found then raise exception '会社が見つかりません'; end if;
  if p_action = 'suspend' then
    update companies set status = 'suspended', court_lock = true where id = c.id;
    perform _notice(c.owner, format('【命令】「%s」は管理者の命令で休業になりました。%s', c.name, coalesce(p_reason, '')));
  elsif p_action = 'resume' then
    update companies set status = 'active', court_lock = false where id = c.id;
    perform _notice(c.owner, format('【命令】「%s」の休業命令がとかれました。営業できます。', c.name));
  elsif p_action = 'bankrupt' then
    perform _corp_close(c.id, 'bankrupt_court', coalesce(nullif(p_reason, ''), '管理者の命令'));
  else
    raise exception 'えらべるのは 休業・再開・倒産 です';
  end if;
  return admin_state();
end $$;

-- ---------------------------------------------------------------------
-- 株の譲渡（代金つき）
--   代金0なら、すぐにゆずる（いままでの「ゆずる」）
--   代金ありなら、相手に「申し出」が届き、相手が受けると代金（＋手数料1%・最低1 Xは国庫へ）を払って株が動く
--   お金が動くので、送金と同じく、どちらも登録から7日・買う人に税の滞納がないこと
-- ---------------------------------------------------------------------
create table if not exists public.share_offers (
  id         bigserial primary key,
  company_id int  not null references public.companies(id) on delete cascade,
  from_user  uuid not null references public.profiles(id) on delete cascade,
  to_user    uuid not null references public.profiles(id) on delete cascade,
  shares     bigint not null check (shares > 0),
  price      bigint not null check (price > 0),       -- 代金の合計（X）
  status     text not null default 'open',            -- open / done / declined / canceled
  created_at timestamptz not null default now(),
  done_at    timestamptz
);
create index if not exists share_offers_to_idx on public.share_offers(to_user, status);
create index if not exists share_offers_from_idx on public.share_offers(from_user, status);
alter table public.share_offers enable row level security;
revoke all on public.share_offers from anon, authenticated;

create or replace function public._offer_json(o share_offers) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', o.id, 'shares', o.shares, 'price', o.price, 'status', o.status, 'at', _dlabel(o.created_at),
    'fee', _xfer_fee(o.price),
    'cid', (select cid from companies where id = o.company_id), 'company', (select name from companies where id = o.company_id),
    'unit', (select case when form = '株式会社' then '株' else '口' end from companies where id = o.company_id),
    'from_name', (select nickname from profiles where id = o.from_user), 'from_id', (select account_no from profiles where id = o.from_user),
    'from_badge', _badge(o.from_user),
    'to_name', (select nickname from profiles where id = o.to_user), 'to_id', (select account_no from profiles where id = o.to_user))
$$;

create or replace function public.share_offer(p_cid text, p_to text, p_shares bigint, p_price bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; mine bigint; t record; me profiles;
begin
  if (select official from companies where cid = _cid_norm(p_cid)) then raise exception '国営の会社には株がありません'; end if;
  if coalesce(p_price, 0) = 0 then
    perform share_give(p_cid, p_to, p_shares);
    return my_stocks();
  end if;
  if p_price < 0 or p_price > 1000000000000 then raise exception '代金は0〜1兆 X にしてください'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません'; end if;
  if p_shares is null or p_shares < 1 then raise exception 'ゆずる数を入れてください'; end if;
  select shares into mine from corp_holders where company_id = c.id and user_id = u;
  if coalesce(mine, 0) < p_shares then raise exception 'ゆずれるのは持っている % までです', coalesce(mine, 0); end if;
  select * into t from _find_id(p_to);
  if t.rid is null then raise exception '株をゆずれるのはユーザーだけです'; end if;
  if t.rid = u then raise exception '自分にはゆずれません'; end if;
  select * into me from profiles where id = u;
  if _now() < me.created_at + interval '7 days' then raise exception '登録から7日たつまで、代金つきの譲渡はできません'; end if;
  if (select count(*) from share_offers where from_user = u and status = 'open') >= 20 then raise exception '返事待ちの申し出は20件までです'; end if;
  insert into share_offers(company_id, from_user, to_user, shares, price, created_at) values (c.id, u, t.rid, p_shares, p_price, _now());
  perform _notice(t.rid, format('【株の譲渡】%s（ID %s）から「%s」の%s %s を %s X でゆずりたいという申し出が来ました。企業タブの「持ち株」から返事できます。',
                  me.nickname, me.account_no, c.name, case when c.form = '株式会社' then '株' else '出資' end, _fmt(p_shares), _fmt(p_price)));
  return my_stocks();
end $$;

-- 申し出に返事する（受ける＝代金を払って株を受け取る）
create or replace function public.share_offer_answer(p_id bigint, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); o share_offers; c companies; me profiles; seller profiles; mine bigint; fee bigint;
begin
  select * into o from share_offers where id = p_id and to_user = u and status = 'open' for update;
  if not found then raise exception '申し出が見つかりません'; end if;
  select * into c from companies where id = o.company_id;
  select * into seller from profiles where id = o.from_user;
  if not p_ok then
    update share_offers set status = 'declined', done_at = _now() where id = o.id;
    perform _notice(o.from_user, format('【株の譲渡】「%s」の株の申し出（#%s）は断られました。', c.name, o.id));
    return my_stocks();
  end if;
  if c.status not in ('active', 'suspended') then raise exception 'この会社はもうありません'; end if;
  select * into me from profiles where id = u for update;
  if _now() < me.created_at + interval '7 days' then raise exception '登録から7日たつまで、代金つきの譲渡は受けられません'; end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので払えません'; end if;
  select shares into mine from corp_holders where company_id = c.id and user_id = o.from_user for update;
  if coalesce(mine, 0) < o.shares then raise exception '相手がもう、その数の株を持っていません'; end if;
  fee := _xfer_fee(o.price);
  if me.balance < o.price + fee then raise exception 'AiliNaXが足りません（手数料 % X をふくめて % X 必要です）', fee, o.price + fee; end if;
  update profiles set balance = balance - (o.price + fee) where id = u;
  update treasury set balance = balance + fee, fee_total = fee_total + fee where id = 1;
  perform _log(u, 'share_buy', o.price + fee, 0, jsonb_build_object('company', c.name, 'shares', o.shares, 'fee', fee));
  perform _give(o.from_user, o.price);
  perform _log(o.from_user, 'share_sell', 0, o.price, jsonb_build_object('company', c.name, 'shares', o.shares));
  update corp_holders set shares = shares - o.shares where company_id = c.id and user_id = o.from_user;
  delete from corp_holders where company_id = c.id and shares <= 0;
  perform _add_shares(c.id, u, o.shares);
  update share_offers set status = 'done', done_at = _now() where id = o.id;
  perform _notice(o.from_user, format('【株の譲渡】%s さんが「%s」の株 %s を %s X で受けました。代金が入りました。', me.nickname, c.name, _fmt(o.shares), _fmt(o.price)));
  return my_stocks() || jsonb_build_object('balance', _bal(u));
end $$;

create or replace function public.share_offer_cancel(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  update share_offers set status = 'canceled', done_at = _now() where id = p_id and from_user = u and status = 'open';
  if not found then raise exception '取り消せる申し出が見つかりません'; end if;
  return my_stocks();
end $$;

-- ---------------------------------------------------------------------
-- 役所の訴え（不正・詐欺などの訴訟・賠償請求）
--   だれでも、相手のID（ユーザーか会社）を訴えられる（返事待ちは1人3件まで・同じ相手には1件）
--   訴えられた人（会社なら社長）は反論を書ける
--   管理者・副管理者が審理する（自分が関係する訴えはだめ。管理者・副管理者が訴えられたものは管理者だけ）
--   認めると：賠償金（相手のお金→訴えた人。足りない分は、相手にお金が入るたびに取り立てる）
--             罰金（国庫へ・あるだけ）・利用停止（日数）・会社の休業命令・倒産
-- ---------------------------------------------------------------------
create table if not exists public.court_cases (
  id             bigserial primary key,
  plaintiff      uuid not null references public.profiles(id) on delete cascade,
  defendant_user uuid references public.profiles(id) on delete cascade,
  defendant_comp int  references public.companies(id) on delete cascade,
  kind           text not null default 'その他',     -- 詐欺 / 不正 / その他
  claim          bigint not null default 0 check (claim >= 0),
  body           text not null,
  evidence       text not null default '',
  status         text not null default 'open',      -- open / judged（認めた）/ dismissed（棄却）/ withdrawn（取り下げ）
  defense        text,
  defense_at     timestamptz,
  verdict        text,
  comp_ordered   bigint not null default 0,
  comp_paid      bigint not null default 0,
  comp_unpaid    bigint not null default 0,
  fine           bigint not null default 0,
  penalties      jsonb not null default '[]',
  judge          uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  decided_at     timestamptz
);
create index if not exists court_cases_unpaid_user_idx on public.court_cases(defendant_user) where comp_unpaid > 0;
create index if not exists court_cases_unpaid_comp_idx on public.court_cases(defendant_comp) where comp_unpaid > 0;
create index if not exists court_cases_status_idx on public.court_cases(status);
alter table public.court_cases enable row level security;
revoke all on public.court_cases from anon, authenticated;

-- 訴えられた側の人（会社なら社長）
create or replace function public._case_def_owner(cc court_cases) returns uuid
language sql stable set search_path = public as $$
  select coalesce(cc.defendant_user, (select owner from companies where id = cc.defendant_comp))
$$;

create or replace function public._case_json(cc court_cases, u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', cc.id, 'kind', cc.kind, 'claim', cc.claim, 'body', cc.body, 'evidence', cc.evidence,
    'status', cc.status, 'defense', cc.defense, 'verdict', cc.verdict, 'at', _dlabel(cc.created_at),
    'decided_at', case when cc.decided_at is null then null else _dlabel(cc.decided_at) end,
    'comp_ordered', cc.comp_ordered, 'comp_paid', cc.comp_paid, 'comp_unpaid', cc.comp_unpaid, 'fine', cc.fine, 'penalties', cc.penalties,
    'p_name', (select nickname from profiles where id = cc.plaintiff), 'p_id', (select account_no from profiles where id = cc.plaintiff),
    'p_badge', _badge(cc.plaintiff),
    'd_name', coalesce((select nickname from profiles where id = cc.defendant_user), (select name from companies where id = cc.defendant_comp)),
    'd_id', coalesce((select account_no from profiles where id = cc.defendant_user), (select _cfull(c) from companies c where c.id = cc.defendant_comp)),
    'd_badge', _badge(_case_def_owner(cc)), 'd_company', cc.defendant_comp is not null,
    'd_owner', (select nickname from profiles where id = _case_def_owner(cc)),
    'mine_p', cc.plaintiff = u, 'mine_d', _case_def_owner(cc) = u)
$$;

-- 自分の訴え（訴えたもの・訴えられたもの）
create or replace function public.court_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return jsonb_build_object(
    'mine', (select coalesce(jsonb_agg(_case_json(cc, u) order by cc.id desc), '[]'::jsonb) from (
              select * from court_cases where plaintiff = u order by id desc limit 30) cc),
    'against', (select coalesce(jsonb_agg(_case_json(cc, u) order by cc.id desc), '[]'::jsonb) from (
              select * from court_cases where defendant_user = u or defendant_comp in (select id from companies where owner = u)
               order by id desc limit 30) cc));
end $$;

-- 訴える
create or replace function public.court_file(p_to text, p_kind text, p_claim bigint, p_body text, p_evidence text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); k text := btrim(coalesce(p_to, '')); du uuid; dc companies; me profiles; owner_u uuid; dname text;
begin
  if p_kind not in ('詐欺', '不正', 'その他') then raise exception '種類（詐欺・不正・その他）をえらんでください'; end if;
  if p_claim is null or p_claim < 0 or p_claim > 1000000000000 then raise exception '賠償してほしい額は0〜1兆 X にしてください'; end if;
  if char_length(btrim(coalesce(p_body, ''))) < 10 then raise exception '何があったか、10文字以上で書いてください'; end if;
  select id, nickname into du, dname from profiles where account_no = k;
  if du is null then
    select * into dc from companies where cid = _cid_norm(k) and status in ('active', 'suspended');
    if dc.id is null then raise exception 'そのIDの人や会社は見つかりません'; end if;
    dname := dc.name; owner_u := dc.owner;
  else
    owner_u := du;
  end if;
  if owner_u = u then raise exception '自分（自分の会社）は訴えられません'; end if;
  if (select count(*) from court_cases where plaintiff = u and status = 'open') >= 3 then raise exception '返事待ちの訴えは3件までです'; end if;
  if exists (select 1 from court_cases where plaintiff = u and status = 'open'
               and (defendant_user = du or defendant_comp = dc.id)) then raise exception 'この相手への訴えは、もう審理中です'; end if;
  select * into me from profiles where id = u;
  insert into court_cases(plaintiff, defendant_user, defendant_comp, kind, claim, body, evidence, created_at)
  values (u, du, dc.id, p_kind, p_claim, left(btrim(p_body), 1000), left(btrim(coalesce(p_evidence, '')), 500), _now());
  perform _notice(owner_u, format('【訴え】%s さん（ID %s）が%sを「%s」で訴えました（賠償の請求 %s X）。役所の「訴え」から反論を書けます。',
                  me.nickname, me.account_no, case when dc.id is null then 'あなた' else '会社「' || dname || '」' end, p_kind, _fmt(p_claim)));
  return court_list();
end $$;

-- 反論を書く（訴えられた人・会社の社長）
create or replace function public.court_defend(p_id bigint, p_text text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); cc court_cases;
begin
  select * into cc from court_cases where id = p_id and status = 'open' for update;
  if not found or _case_def_owner(cc) is distinct from u then raise exception '反論できる訴えが見つかりません'; end if;
  if char_length(btrim(coalesce(p_text, ''))) < 1 then raise exception '反論を書いてください'; end if;
  update court_cases set defense = left(btrim(p_text), 1000), defense_at = _now() where id = cc.id;
  perform _notice(cc.plaintiff, format('【訴え #%s】相手が反論を書きました。', cc.id));
  return court_list();
end $$;

-- 訴えを取り下げる（訴えた人）
create or replace function public.court_withdraw(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); cc court_cases;
begin
  select * into cc from court_cases where id = p_id and plaintiff = u and status = 'open' for update;
  if not found then raise exception '取り下げられる訴えが見つかりません'; end if;
  update court_cases set status = 'withdrawn', decided_at = _now() where id = cc.id;
  perform _notice(_case_def_owner(cc), format('【訴え #%s】訴えは取り下げられました。', cc.id));
  return court_list();
end $$;

-- 払いきれていない賠償金を取り立てる（ユーザー：入ってきた額まで／会社：入ってきた額まで）
create or replace function public._court_collect_user(u uuid, amt bigint) returns void
language plpgsql set search_path = public as $$
declare r court_cases; left_amt bigint := amt; pay bigint; b bigint;
begin
  for r in select * from court_cases where defendant_user = u and comp_unpaid > 0 order by id for update loop
    exit when left_amt <= 0;
    select balance into b from profiles where id = u;
    pay := least(r.comp_unpaid, left_amt, b);
    exit when pay <= 0;
    update profiles set balance = balance - pay where id = u;
    update court_cases set comp_paid = comp_paid + pay, comp_unpaid = comp_unpaid - pay where id = r.id;
    perform _log(u, 'court_garnish', pay, 0, jsonb_build_object('case', r.id));
    perform _give(r.plaintiff, pay);
    perform _log(r.plaintiff, 'court_comp', 0, pay, jsonb_build_object('case', r.id));
    perform _notice(u, format('【訴え #%s】入ってきたお金から、賠償金 %s X を取り立てました（残り %s X）。', r.id, _fmt(pay), _fmt(r.comp_unpaid - pay)));
    perform _notice(r.plaintiff, format('【訴え #%s】賠償金 %s X が入りました（残り %s X）。', r.id, _fmt(pay), _fmt(r.comp_unpaid - pay)));
    left_amt := left_amt - pay;
  end loop;
end $$;

create or replace function public._court_collect_comp(cid_int int, amt bigint) returns void
language plpgsql set search_path = public as $$
declare r court_cases; left_amt bigint := amt; pay bigint; b bigint;
begin
  for r in select * from court_cases where defendant_comp = cid_int and comp_unpaid > 0 order by id for update loop
    exit when left_amt <= 0;
    select balance into b from companies where id = cid_int;
    pay := least(r.comp_unpaid, left_amt, b);
    exit when pay <= 0;
    perform _corp_move(cid_int, -pay, 'court', format('訴え #%s の賠償金（取り立て）', r.id));
    update court_cases set comp_paid = comp_paid + pay, comp_unpaid = comp_unpaid - pay where id = r.id;
    perform _give(r.plaintiff, pay);
    perform _log(r.plaintiff, 'court_comp', 0, pay, jsonb_build_object('case', r.id));
    perform _notice(r.plaintiff, format('【訴え #%s】賠償金 %s X が入りました（残り %s X）。', r.id, _fmt(pay), _fmt(r.comp_unpaid - pay)));
    left_amt := left_amt - pay;
  end loop;
end $$;

-- 審理する（管理者・副管理者）
--   p_ok：認める／棄却。認めるとき：p_comp 賠償金（請求額まで）・p_fine 罰金・p_ban_days 利用停止の日数・p_corp 会社の処分（none / suspend / bankrupt）
create or replace function public.admin_court_decide(p_id bigint, p_ok boolean, p_comp bigint, p_fine bigint, p_ban_days int, p_corp text, p_verdict text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); rl text := _role(u); cc court_cases; downer uuid; dc companies; pen jsonb := '[]'::jsonb;
  got bigint := 0; take bigint; fine_got bigint := 0; r record; vtxt text := left(btrim(coalesce(p_verdict, '')), 1000);
begin
  if rl is null then raise exception '管理者だけが使えます'; end if;
  select * into cc from court_cases where id = p_id and status = 'open' for update;
  if not found then raise exception '審理中の訴えが見つかりません'; end if;
  downer := _case_def_owner(cc);
  if u in (cc.plaintiff, downer) then raise exception '自分が関係する訴えは審理できません'; end if;
  if rl <> 'admin' and (_role(cc.plaintiff) is not null or _role(downer) is not null) then
    raise exception '管理者・副管理者が関係する訴えは、管理者だけが審理できます';
  end if;
  if char_length(vtxt) < 1 then raise exception '判決の理由を書いてください'; end if;
  if not p_ok then
    update court_cases set status = 'dismissed', verdict = vtxt, judge = u, decided_at = _now() where id = cc.id;
    perform _notice(cc.plaintiff, format('【訴え #%s】訴えは認められませんでした（棄却）。理由：%s', cc.id, vtxt));
    perform _notice(downer, format('【訴え #%s】あなたへの訴えは認められませんでした（棄却）。', cc.id));
    return admin_state();
  end if;
  p_comp := greatest(coalesce(p_comp, 0), 0); p_fine := greatest(coalesce(p_fine, 0), 0);
  p_ban_days := greatest(coalesce(p_ban_days, 0), 0); p_corp := coalesce(p_corp, 'none');
  if p_comp > cc.claim then raise exception '賠償金は、請求された額（% X）までです', cc.claim; end if;
  if p_ban_days > 365 then raise exception '利用停止は365日までです'; end if;
  if p_corp not in ('none', 'suspend', 'bankrupt') then raise exception '会社の処分は なし・休業・倒産 です'; end if;
  if p_corp <> 'none' and cc.defendant_comp is null then raise exception '会社の処分は、会社を訴えたときだけです'; end if;
  if cc.defendant_comp is not null then select * into dc from companies where id = cc.defendant_comp for update; end if;
  -- 賠償金
  if p_comp > 0 then
    if cc.defendant_user is not null then
      take := least(p_comp, (select balance from profiles where id = cc.defendant_user));
      if take > 0 then update profiles set balance = balance - take where id = cc.defendant_user; got := got + take; end if;
      for r in select * from bank_accounts where user_id = cc.defendant_user and balance > 0 order by balance desc loop
        exit when got >= p_comp;
        take := least(p_comp - got, r.balance);
        update bank_accounts set balance = balance - take where company_id = r.company_id and user_id = r.user_id;
        got := got + take;
      end loop;
      if got > 0 then perform _log(cc.defendant_user, 'court_pay', got, 0, jsonb_build_object('case', cc.id)); end if;
    else
      take := least(p_comp, dc.balance);
      if take > 0 then perform _corp_move(dc.id, -take, 'court', format('訴え #%s の賠償金', cc.id)); got := take; end if;
    end if;
    if got > 0 then
      perform _give(cc.plaintiff, got);
      perform _log(cc.plaintiff, 'court_comp', 0, got, jsonb_build_object('case', cc.id));
    end if;
    pen := pen || jsonb_build_array(format('賠償金 %s X（払えた額 %s X）', _fmt(p_comp), _fmt(got)));
  end if;
  update court_cases set comp_ordered = p_comp, comp_paid = got, comp_unpaid = p_comp - got where id = cc.id;
  -- 罰金（あるだけ。国庫へ）
  if p_fine > 0 then
    if cc.defendant_user is not null then
      fine_got := least(p_fine, (select balance from profiles where id = cc.defendant_user));
      if fine_got > 0 then
        update profiles set balance = balance - fine_got where id = cc.defendant_user;
        perform _log(cc.defendant_user, 'court_fine', fine_got, 0, jsonb_build_object('case', cc.id));
      end if;
    else
      fine_got := least(p_fine, (select balance from companies where id = dc.id));
      if fine_got > 0 then perform _corp_move(dc.id, -fine_got, 'court', format('訴え #%s の罰金', cc.id)); end if;
    end if;
    if fine_got > 0 then
      update treasury set balance = balance + fine_got, confiscated_total = confiscated_total + fine_got where id = 1;
    end if;
    pen := pen || jsonb_build_array(format('罰金 %s X', _fmt(fine_got)));
  end if;
  -- 利用停止（ユーザー。会社なら社長）
  if p_ban_days > 0 then
    update profiles set banned_until = greatest(coalesce(banned_until, _now()), _now()) + make_interval(days => p_ban_days) where id = downer;
    pen := pen || jsonb_build_array(format('利用停止 %s日', p_ban_days));
  end if;
  -- 会社の処分
  if p_corp = 'suspend' then
    update companies set status = 'suspended', court_lock = true where id = dc.id and status in ('active', 'suspended');
    pen := pen || jsonb_build_array('会社の休業命令');
  elsif p_corp = 'bankrupt' then
    perform _corp_close(dc.id, 'bankrupt_court', format('訴え #%s の判決', cc.id));
    pen := pen || jsonb_build_array('会社の倒産');
  end if;
  update court_cases set status = 'judged', verdict = vtxt, fine = fine_got, penalties = pen, judge = u, decided_at = _now() where id = cc.id;
  perform _notice(cc.plaintiff, format('【訴え #%s】訴えが認められました。%s 理由：%s', cc.id,
                  (select string_agg(x, '・') from jsonb_array_elements_text(pen) x), vtxt));
  perform _notice(downer, format('【訴え #%s】あなたへの訴えが認められました。処分：%s。理由：%s', cc.id,
                  coalesce((select string_agg(x, '・') from jsonb_array_elements_text(pen) x), '注意'), vtxt));
  return admin_state();
end $$;


-- ---------------------------------------------------------------------
-- 銀行の貸出パック（借入）
--   銀行が「パック」を作る：名前・貸す額・期間（日）・利息（期間全体で何%）・延滞の利息（1日あたり%）
--                         ・申込をすぐ通すか（auto）・1人が同時に借りられる数・受付中か
--   借りたい人はパックに申し込む → 銀行が許可（auto ならすぐ）→ 銀行の会社のお金から本人へ
--   返すのはいつでも・少しずつでもOK。期限を過ぎると延滞の利息がつき、本人にお金が入るたびに銀行が取り立てる
--   銀行が廃業・倒産したら、貸している分は帳消し
-- ---------------------------------------------------------------------
create table if not exists public.loan_packs (
  id           bigserial primary key,
  company_id   int not null references public.companies(id) on delete cascade,
  name         text not null,
  amount       bigint not null check (amount > 0),
  days         int not null check (days > 0),
  rate         numeric not null default 0 check (rate >= 0),        -- 期間全体の利息（%）
  late_rate    numeric not null default 0 check (late_rate >= 0),   -- 延滞の利息（1日あたり%）
  auto         boolean not null default false,
  max_per_user int not null default 1,
  active       boolean not null default true,
  description  text not null default '',
  created_at   timestamptz not null default now()
);
create table if not exists public.loans (
  id          bigserial primary key,
  pack_id     bigint references public.loan_packs(id) on delete set null,
  company_id  int not null references public.companies(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  pack_name   text not null,
  principal   bigint not null,
  interest    bigint not null default 0,
  days        int not null,
  late_rate   numeric not null default 0,
  late_fee    bigint not null default 0,
  late_day    date,
  repaid      bigint not null default 0,
  status      text not null default 'pending',   -- pending / active / repaid / rejected / canceled / forgiven
  applied_at  timestamptz not null default now(),
  started_at  timestamptz,
  due_at      timestamptz,
  closed_at   timestamptz
);
create index if not exists loans_user_idx on public.loans(user_id, status);
create index if not exists loans_company_idx on public.loans(company_id, status);
alter table public.loan_packs enable row level security;
alter table public.loans enable row level security;
revoke all on public.loan_packs, public.loans from anon, authenticated;

create or replace function public._pack_json(lp loan_packs) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', lp.id, 'name', lp.name, 'amount', lp.amount, 'days', lp.days, 'rate', lp.rate, 'late_rate', lp.late_rate,
    'auto', lp.auto, 'max_per_user', lp.max_per_user, 'active', lp.active, 'description', lp.description,
    'repay', lp.amount + ceil(lp.amount * lp.rate / 100)::bigint)
$$;

-- 延滞の利息を、前回から今日までの分つける
create or replace function public._loan_accrue(lid bigint) returns void
language plpgsql set search_path = public as $$
declare l loans; d0 date; days int; owed bigint; add bigint;
begin
  select * into l from loans where id = lid for update;
  if l.status <> 'active' or l.due_at >= _now() or l.late_rate <= 0 then return; end if;
  d0 := coalesce(l.late_day, _kb_jday(l.due_at));
  days := _kb_jday(_now()) - d0;
  if days <= 0 then return; end if;
  owed := l.principal + l.interest + l.late_fee - l.repaid;
  add := ceil(owed * l.late_rate / 100 * days)::bigint;
  update loans set late_fee = late_fee + greatest(add, 0), late_day = _kb_jday(_now()) where id = lid;
end $$;

-- 返す残り
create or replace function public._loan_owed(lid bigint) returns bigint
language sql stable set search_path = public as $$
  select greatest(principal + interest + late_fee - repaid, 0) from loans where id = lid
$$;

create or replace function public._loan_json(l loans) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', l.id, 'pack', l.pack_name, 'principal', l.principal, 'interest', l.interest, 'late_fee', l.late_fee,
    'repaid', l.repaid, 'owed', greatest(l.principal + l.interest + l.late_fee - l.repaid, 0), 'status', l.status, 'days', l.days,
    'late_rate', l.late_rate, 'overdue', l.status = 'active' and l.due_at < _now(),
    'applied', _dlabel(l.applied_at), 'due', case when l.due_at is null then null else _dlabel(l.due_at) end,
    'bank', (select name from companies where id = l.company_id), 'cid', (select cid from companies where id = l.company_id),
    'nickname', (select nickname from profiles where id = l.user_id), 'uid', (select account_no from profiles where id = l.user_id),
    'badge', _badge(l.user_id),
    -- 申込の審査用：この人のこれまで（返した・帳消し・いま延滞中）
    'history', jsonb_build_object(
      'repaid', (select count(*) from loans x where x.user_id = l.user_id and x.status = 'repaid'),
      'active', (select count(*) from loans x where x.user_id = l.user_id and x.status = 'active'),
      'overdue', (select count(*) from loans x where x.user_id = l.user_id and x.status = 'active' and x.due_at < _now()),
      'forgiven', (select count(*) from loans x where x.user_id = l.user_id and x.status = 'forgiven')))
$$;

-- 貸し出す（銀行のお金 → 本人）
create or replace function public._loan_start(lid bigint) returns void
language plpgsql set search_path = public as $$
declare l loans; c companies; lp loan_packs;
begin
  select * into l from loans where id = lid for update;
  select * into c from companies where id = l.company_id for update;
  if c.status <> 'active' then raise exception 'この銀行はいま営業していません'; end if;
  if c.balance < l.principal then raise exception '銀行のお金が足りないので貸せません（%）', c.name; end if;
  perform _corp_move(c.id, -l.principal, 'loan', format('貸出 #%s（%s さん）', l.id, (select nickname from profiles where id = l.user_id)));
  update profiles set balance = balance + l.principal where id = l.user_id;
  perform _log(l.user_id, 'loan', 0, l.principal, jsonb_build_object('bank', c.name, 'loan', l.id));
  update loans set status = 'active', started_at = _now(), due_at = _now() + make_interval(days => l.days) where id = l.id;
  perform _notice(l.user_id, format('【借入 #%s】「%s」から %s X を借りました。%s までに %s X を返してください。',
                  l.id, c.name, _fmt(l.principal), _dlabel(_now() + make_interval(days => l.days)), _fmt(l.principal + l.interest)));
end $$;

-- 申し込む（auto のパックはすぐ借りられる）
create or replace function public.loan_apply(p_pack bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); lp loan_packs; c companies; me profiles; lid bigint;
begin
  select * into lp from loan_packs where id = p_pack and active;
  if not found then raise exception 'そのパックはいま受け付けていません'; end if;
  select * into c from companies where id = lp.company_id and status = 'active' and kind = '銀行';
  if not found then raise exception 'この銀行はいま営業していません'; end if;
  if c.owner = u then raise exception '自分の銀行からは借りられません'; end if;
  if not c.loan_on then raise exception 'この銀行はいま貸出の受付をしていません'; end if;
  if c.loan_need_acct and not exists (select 1 from bank_accounts where company_id = c.id and user_id = u and status = 'active') then
    raise exception 'この銀行で借りるには、先にこの銀行の口座が必要です';
  end if;
  if c.loan_need_check and not coalesce((_badge(u)->>'ok')::boolean, false) then
    raise exception 'この銀行で借りるには、オレンジのチェックが必要です';
  end if;
  select * into me from profiles where id = u;
  if _now() < me.created_at + interval '7 days' then raise exception '登録から7日たつまで借りられません'; end if;
  if exists (select 1 from loans where user_id = u and pack_id = lp.id and status = 'pending') then raise exception 'このパックはもう申込中です'; end if;
  if (select count(*) from loans where user_id = u and pack_id = lp.id and status = 'active') >= lp.max_per_user then
    raise exception 'このパックで同時に借りられるのは %件までです', lp.max_per_user;
  end if;
  insert into loans(pack_id, company_id, user_id, pack_name, principal, interest, days, late_rate, applied_at)
  values (lp.id, c.id, u, lp.name, lp.amount, ceil(lp.amount * lp.rate / 100)::bigint, lp.days, lp.late_rate, _now()) returning id into lid;
  if lp.auto then
    perform _loan_start(lid);
  else
    perform _notice(c.owner, format('【借入の申込】%s さん（ID %s）が「%s」の「%s」（%s X）を申し込みました。仕事タブの企業ページで審査できます。',
                    me.nickname, me.account_no, c.name, lp.name, _fmt(lp.amount)));
  end if;
  return corp_page(c.cid) || jsonb_build_object('started', lp.auto);
end $$;

-- 申込を取り消す（本人）
create or replace function public.loan_cancel(p_loan bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  update loans set status = 'canceled', closed_at = _now() where id = p_loan and user_id = u and status = 'pending';
  if not found then raise exception '取り消せる申込が見つかりません'; end if;
  return my_banks();
end $$;

-- 返す（いつでも・少しずつでもOK）
create or replace function public.loan_repay(p_loan bigint, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); l loans; owed bigint; pay bigint; c companies;
begin
  perform _loan_accrue(p_loan);
  select * into l from loans where id = p_loan and user_id = u and status = 'active' for update;
  if not found then raise exception '返せる借入が見つかりません'; end if;
  owed := _loan_owed(l.id);
  pay := least(coalesce(p_amount, owed), owed);
  if pay < 1 then raise exception '1 X以上にしてください'; end if;
  perform _take(u, pay);
  select * into c from companies where id = l.company_id;
  perform _corp_move(c.id, pay, 'loan_repay', format('返済 #%s（%s さん）', l.id, (select nickname from profiles where id = u)));
  update loans set repaid = repaid + pay where id = l.id;
  perform _log(u, 'loan_repay', pay, 0, jsonb_build_object('bank', c.name, 'loan', l.id));
  if pay >= owed then
    update loans set status = 'repaid', closed_at = _now() where id = l.id;
    perform _notice(c.owner, format('【返済】%s さんが借入 #%s（%s）を返し終わりました。', (select nickname from profiles where id = u), l.id, l.pack_name));
  end if;
  return my_banks() || jsonb_build_object('balance', _bal(u), 'paid', pay);
end $$;

-- 期限を過ぎた借入を、入ってきたお金から取り立てる
create or replace function public._loan_collect(u uuid, amt bigint) returns void
language plpgsql set search_path = public as $$
declare l loans; left_amt bigint := amt; pay bigint; owed bigint; b bigint;
begin
  for l in select * from loans where user_id = u and status = 'active' and due_at < _now() order by due_at for update loop
    exit when left_amt <= 0;
    perform _loan_accrue(l.id);
    owed := _loan_owed(l.id);
    select balance into b from profiles where id = u;
    pay := least(owed, left_amt, b);
    exit when pay <= 0;
    update profiles set balance = balance - pay where id = u;
    update loans set repaid = repaid + pay where id = l.id;
    perform _log(u, 'loan_collect', pay, 0, jsonb_build_object('loan', l.id));
    if exists (select 1 from companies where id = l.company_id and status in ('active', 'suspended')) then
      perform _corp_move(l.company_id, pay, 'loan_repay', format('返済 #%s（期限切れの取り立て）', l.id));
    end if;
    if pay >= owed then update loans set status = 'repaid', closed_at = _now() where id = l.id; end if;
    perform _notice(u, format('【借入 #%s】返す期限を過ぎているので、入ってきたお金から %s X を取り立てました（残り %s X）。', l.id, _fmt(pay), _fmt(owed - pay)));
    left_amt := left_amt - pay;
  end loop;
end $$;

-- 自分の借入（全部の銀行）
create or replace function public.my_loans() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r record;
begin
  for r in select id from loans where user_id = u and status = 'active' and due_at < _now() loop perform _loan_accrue(r.id); end loop;
  return (select coalesce(jsonb_agg(_loan_json(l) order by (l.status in ('pending', 'active')) desc, l.id desc), '[]'::jsonb) from (
            select * from loans where user_id = u order by id desc limit 30) l);
end $$;

-- 銀行（社長）：口座の申込を許可・断る
create or replace function public.bank_acct_answer(p_cid text, p_user text, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; t uuid;
begin
  c := _my_corp(u, p_cid);
  select id into t from profiles where account_no = btrim(coalesce(p_user, ''));
  if t is null or not exists (select 1 from bank_accounts where company_id = c.id and user_id = t and status = 'pending') then raise exception '申込が見つかりません'; end if;
  if p_ok then
    update bank_accounts set status = 'active', interest_day = _kb_jday(_now()) where company_id = c.id and user_id = t;
    perform _notice(t, format('【口座】「%s」の口座ができました。預けられます。', c.name));
  else
    delete from bank_accounts where company_id = c.id and user_id = t;
    perform _notice(t, format('【口座】「%s」の口座の申込は断られました。', c.name));
  end if;
  return my_corps();
end $$;

-- 銀行（社長）：口座開設と借入の受付を決める
drop function if exists public.bank_settings(text, text);
create or replace function public.bank_settings(p_cid text, p_acct_mode text, p_acct_check boolean, p_loan_on boolean, p_loan_acct boolean, p_loan_check boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if c.kind <> '銀行' then raise exception '銀行だけの設定です'; end if;
  if p_acct_mode not in ('off', 'auto', 'approve') then raise exception '口座開設は「受け付けない」「すぐ」「許可制」です'; end if;
  update companies set acct_mode = p_acct_mode, acct_need_check = coalesce(p_acct_check, false), loan_on = coalesce(p_loan_on, true),
         loan_need_acct = coalesce(p_loan_acct, false), loan_need_check = coalesce(p_loan_check, false)
   where id = c.id;
  return my_corps();
end $$;

-- 銀行（社長）：パックを作る・変える
create or replace function public.loan_pack_save(p_cid text, p_pack bigint, p_name text, p_amount bigint, p_days int, p_rate numeric,
  p_late_rate numeric, p_auto boolean, p_max int, p_active boolean, p_desc text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; nm text := btrim(coalesce(p_name, ''));
begin
  c := _my_corp(u, p_cid);
  if c.kind <> '銀行' then raise exception '貸出パックは銀行だけです'; end if;
  if char_length(nm) < 1 or char_length(nm) > 40 then raise exception 'パックの名前は1〜40文字です'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000000000 then raise exception '貸す額は1 X以上にしてください'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception '期間は1〜365日です'; end if;
  if p_rate is null or p_rate < 0 or p_rate > 1000 then raise exception '利息は0〜1000%%です'; end if;
  if p_late_rate is null or p_late_rate < 0 or p_late_rate > 100 then raise exception '延滞の利息は1日0〜100%%です'; end if;
  if p_max is null or p_max < 1 or p_max > 100 then raise exception '同時に借りられる数は1〜100です'; end if;
  if p_pack is null then
    if (select count(*) from loan_packs where company_id = c.id) >= 20 then raise exception 'パックは20個までです'; end if;
    insert into loan_packs(company_id, name, amount, days, rate, late_rate, auto, max_per_user, active, description)
    values (c.id, nm, p_amount, p_days, p_rate, p_late_rate, coalesce(p_auto, false), p_max, coalesce(p_active, true), left(coalesce(p_desc, ''), 300));
  else
    update loan_packs set name = nm, amount = p_amount, days = p_days, rate = p_rate, late_rate = p_late_rate, auto = coalesce(p_auto, auto),
           max_per_user = p_max, active = coalesce(p_active, active), description = left(coalesce(p_desc, ''), 300)
     where id = p_pack and company_id = c.id;
    if not found then raise exception 'そのパックはありません'; end if;
  end if;
  return my_corps();
end $$;

-- 銀行（社長）：借入の申込を許可・断る
create or replace function public.loan_answer(p_loan bigint, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); l loans; c companies;
begin
  select * into l from loans where id = p_loan and status = 'pending' for update;
  if not found then raise exception '申込が見つかりません'; end if;
  select * into c from companies where id = l.company_id and owner = u;
  if not found then raise exception 'あなたの銀行への申込ではありません'; end if;
  if p_ok then
    perform _loan_start(l.id);
  else
    update loans set status = 'rejected', closed_at = _now() where id = l.id;
    perform _notice(l.user_id, format('【借入】「%s」への「%s」の申込は断られました。', c.name, l.pack_name));
  end if;
  return my_corps();
end $$;


-- ---------------------------------------------------------------------
-- 対戦ゲーム（リバーシ・チェス・将棋…）
--   部屋：主催が作る（ゲーム・持ち時間・招待・観戦の賭けあり／なし）。だれでも入れる部屋と、IDで招待した人だけの部屋
--   ふたりそろうと始まる（先手・後手はランダム）。持ち時間は1人ずつ（最大3時間）。切れたら負け
--   本人どうしは賭けない（無料）。観戦する人は、どちらが勝つかに賭けられる（山分け。国庫が5%）
--     ・賭けられるのは10手目まで（それ以降は締め切り）・対局している本人は賭けられない
--     ・引き分け・片方にしか賭けがないときは全部返す
--   チャット：10秒に1回・100文字まで
-- ---------------------------------------------------------------------
create table if not exists public.game_rooms (
  id          bigserial primary key,
  game        text not null,                        -- reversi / chess / shogi
  title       text not null default '',
  host        uuid not null references public.profiles(id) on delete cascade,
  invite      uuid references public.profiles(id) on delete set null,
  seats       uuid[] not null default '{}',          -- 席0（先手・黒）, 席1（後手・白）
  status      text not null default 'waiting',      -- waiting / playing / finished / canceled
  time_ms     int not null default 600000,          -- 1人の持ち時間
  clock_ms    int[] not null default '{}',          -- 残り時間（席ごと）
  turn        int not null default 0,
  turn_at     timestamptz,
  move_no     int not null default 0,
  state       jsonb not null default '{}',
  bets_on     boolean not null default true,
  winner      int,                                   -- 勝った席（引き分けは -1）
  reason      text,
  created_at  timestamptz not null default now(),
  started_at  timestamptz,
  finished_at timestamptz
);
create index if not exists game_rooms_status_idx on public.game_rooms(status, game, id desc);
create table if not exists public.game_moves (
  room_id bigint not null references public.game_rooms(id) on delete cascade,
  n       int not null,
  seat    int not null,
  move    jsonb not null,
  at      timestamptz not null default now(),
  primary key (room_id, n)
);
create table if not exists public.game_bets (
  id      bigserial primary key,
  room_id bigint not null references public.game_rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  seat    int not null,
  amount  bigint not null check (amount > 0),
  payout  bigint,
  at      timestamptz not null default now()
);
create index if not exists game_bets_room_idx on public.game_bets(room_id);
create table if not exists public.game_chat (
  id      bigserial primary key,
  room_id bigint not null references public.game_rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body    text not null,
  at      timestamptz not null default now()
);
create index if not exists game_chat_room_idx on public.game_chat(room_id, id desc);
alter table public.game_rooms add column if not exists draw_offer int;    -- 引き分けを申し出た席
alter table public.game_rooms enable row level security;
alter table public.game_moves enable row level security;
alter table public.game_bets  enable row level security;
alter table public.game_chat  enable row level security;
revoke all on public.game_rooms, public.game_moves, public.game_bets, public.game_chat from anon, authenticated;

-- ---------- リバーシ（8×8。盤は64文字：. 空き / B 黒 / W 白。黒が先手＝席0） ----------
create or replace function public._rv_flips(b text, pos int, me text) returns int[]
language plpgsql immutable as $$
declare op text := case me when 'B' then 'W' else 'B' end; r int := pos / 8; c int := pos % 8;
  dr int; dc int; rr int; cc int; line int[]; res int[] := '{}';
begin
  if pos < 0 or pos > 63 or substr(b, pos + 1, 1) <> '.' then return '{}'; end if;
  foreach dr in array array[-1, 0, 1] loop
    foreach dc in array array[-1, 0, 1] loop
      continue when dr = 0 and dc = 0;
      line := '{}'; rr := r + dr; cc := c + dc;
      while rr between 0 and 7 and cc between 0 and 7 and substr(b, rr * 8 + cc + 1, 1) = op loop
        line := line || (rr * 8 + cc); rr := rr + dr; cc := cc + dc;
      end loop;
      if cardinality(line) > 0 and rr between 0 and 7 and cc between 0 and 7 and substr(b, rr * 8 + cc + 1, 1) = me then
        res := res || line;
      end if;
    end loop;
  end loop;
  return res;
end $$;

create or replace function public._rv_legal(b text, me text) returns int[]
language plpgsql immutable as $$
declare i int; res int[] := '{}';
begin
  for i in 0..63 loop
    if substr(b, i + 1, 1) = '.' and cardinality(_rv_flips(b, i, me)) > 0 then res := res || i; end if;
  end loop;
  return res;
end $$;

-- 手を打つ：新しい状態（next：次の席、over：終わり、winner：勝った席 / -1 引き分け）
create or replace function public._rv_apply(st jsonb, seat int, mv jsonb) returns jsonb
language plpgsql immutable as $$
declare b text := st->>'board'; me text := case seat when 0 then 'B' else 'W' end; op text := case seat when 0 then 'W' else 'B' end;
  pos int; fl int[]; i int; nb int; nw int; nxt int; passed boolean := false;
begin
  if jsonb_typeof(mv->'pos') <> 'number' then raise exception '置く場所をえらんでください'; end if;
  pos := (mv->>'pos')::int;
  fl := _rv_flips(b, pos, me);
  if cardinality(fl) = 0 then raise exception 'そこには置けません'; end if;
  b := overlay(b placing me from pos + 1 for 1);
  foreach i in array fl loop b := overlay(b placing me from i + 1 for 1); end loop;
  nb := length(b) - length(replace(b, 'B', '')); nw := length(b) - length(replace(b, 'W', ''));
  if cardinality(_rv_legal(b, op)) > 0 then nxt := 1 - seat;
  elsif cardinality(_rv_legal(b, me)) > 0 then nxt := seat; passed := true;   -- 相手は置けないのでパス
  else
    return jsonb_build_object('board', b, 'last', pos, 'flips', to_jsonb(fl), 'over', true, 'black', nb, 'white', nw,
      'winner', case when nb > nw then 0 when nw > nb then 1 else -1 end, 'reason', format('黒 %s・白 %s', nb, nw));
  end if;
  return jsonb_build_object('board', b, 'last', pos, 'flips', to_jsonb(fl), 'next', nxt, 'pass', passed, 'over', false, 'black', nb, 'white', nw);
end $$;

-- ---------- チェス（8×8。盤は64文字：白は大文字 KQRBNP、黒は小文字。. は空き。0 番が a8、63 番が h1。白が先手＝席0） ----------
create or replace function public._ch_at(b text, r int, c int) returns text
language sql immutable as $$ select case when r between 0 and 7 and c between 0 and 7 then substr(b, r * 8 + c + 1, 1) else '#' end $$;

-- sq が byw（白なら true）の駒にきかれているか
create or replace function public._ch_attacked(b text, sq int, byw boolean) returns boolean
language plpgsql immutable as $$
declare r int := sq / 8; c int := sq % 8; d int[]; rr int; cc int; p text; i int;
  kn int[] := array[-2,-1, -2,1, -1,-2, -1,2, 1,-2, 1,2, 2,-1, 2,1];
  kg int[] := array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,-1, 1,0, 1,1];
  orth int[] := array[-1,0, 1,0, 0,-1, 0,1]; diag int[] := array[-1,-1, -1,1, 1,-1, 1,1];
begin
  -- ポーン
  if byw then
    if _ch_at(b, r + 1, c - 1) = 'P' or _ch_at(b, r + 1, c + 1) = 'P' then return true; end if;
  else
    if _ch_at(b, r - 1, c - 1) = 'p' or _ch_at(b, r - 1, c + 1) = 'p' then return true; end if;
  end if;
  for i in 0..7 loop
    if _ch_at(b, r + kn[i * 2 + 1], c + kn[i * 2 + 2]) = (case when byw then 'N' else 'n' end) then return true; end if;
    if _ch_at(b, r + kg[i * 2 + 1], c + kg[i * 2 + 2]) = (case when byw then 'K' else 'k' end) then return true; end if;
  end loop;
  for i in 0..3 loop
    rr := r + orth[i * 2 + 1]; cc := c + orth[i * 2 + 2];
    loop
      p := _ch_at(b, rr, cc);
      exit when p <> '.';
      rr := rr + orth[i * 2 + 1]; cc := cc + orth[i * 2 + 2];
    end loop;
    if p in (case when byw then 'R' else 'r' end, case when byw then 'Q' else 'q' end) then return true; end if;
    rr := r + diag[i * 2 + 1]; cc := c + diag[i * 2 + 2];
    loop
      p := _ch_at(b, rr, cc);
      exit when p <> '.';
      rr := rr + diag[i * 2 + 1]; cc := cc + diag[i * 2 + 2];
    end loop;
    if p in (case when byw then 'B' else 'b' end, case when byw then 'Q' else 'q' end) then return true; end if;
  end loop;
  return false;
end $$;

-- 盤の上で手を動かす（アンパッサン・キャスリング・成りもふくむ）
create or replace function public._ch_make(b text, f int, t int, promo text, ep int) returns text
language plpgsql immutable as $$
declare p text := substr(b, f + 1, 1); w boolean := p = upper(p);
begin
  b := overlay(b placing '.' from f + 1 for 1);
  if lower(p) = 'p' and t = ep and ep >= 0 then        -- アンパッサン：うしろのポーンをとる
    b := overlay(b placing '.' from (case when w then t + 8 else t - 8 end) + 1 for 1);
  end if;
  if lower(p) = 'k' and abs(t - f) = 2 then             -- キャスリング：ルークも動かす
    if t > f then b := overlay(overlay(b placing '.' from f + 3 + 1 for 1) placing (case when w then 'R' else 'r' end) from f + 1 + 1 for 1);
    else b := overlay(overlay(b placing '.' from f - 4 + 1 for 1) placing (case when w then 'R' else 'r' end) from f - 1 + 1 for 1); end if;
  end if;
  if lower(p) = 'p' and (t / 8 = 0 or t / 8 = 7) then p := case when w then upper(coalesce(promo, 'q')) else lower(coalesce(promo, 'q')) end; end if;
  return overlay(b placing p from t + 1 for 1);
end $$;

-- 指せる手（{f, t, p}）。p は成るときの駒（q/r/b/n）
create or replace function public._ch_legal(st jsonb, w boolean) returns jsonb
language plpgsql immutable as $$
declare b text := st->>'board'; cas text := coalesce(st->>'castle', ''); ep int := coalesce((st->>'ep')::int, -1);
  res jsonb := '[]'::jsonb; sq int; r int; c int; p text; t int; rr int; cc int; i int; k int; dir int; q text; nb text; ks int;
  mine text := case when w then 'KQRBNP' else 'kqrbnp' end; theirs text := case when w then 'kqrbnp' else 'KQRBNP' end;
  kn int[] := array[-2,-1, -2,1, -1,-2, -1,2, 1,-2, 1,2, 2,-1, 2,1];
  kg int[] := array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,-1, 1,0, 1,1];
  pseudo int[] := '{}';   -- f, t, 成り（0=なし 1=q 2=r 3=b 4=n）を3つずつ
begin
  for sq in 0..63 loop
    p := substr(b, sq + 1, 1);
    continue when strpos(mine, p) = 0;
    r := sq / 8; c := sq % 8;
    if lower(p) = 'p' then
      dir := case when w then -1 else 1 end;
      rr := r + dir;
      if _ch_at(b, rr, c) = '.' then
        if rr = 0 or rr = 7 then pseudo := pseudo || array[sq, rr * 8 + c, 1, sq, rr * 8 + c, 2, sq, rr * 8 + c, 3, sq, rr * 8 + c, 4];
        else pseudo := pseudo || array[sq, rr * 8 + c, 0]; end if;
        if (w and r = 6 or not w and r = 1) and _ch_at(b, r + 2 * dir, c) = '.' then pseudo := pseudo || array[sq, (r + 2 * dir) * 8 + c, 0]; end if;
      end if;
      foreach k in array array[-1, 1] loop
        cc := c + k;
        continue when cc < 0 or cc > 7;
        if strpos(theirs, _ch_at(b, rr, cc)) > 0 or rr * 8 + cc = ep then
          if rr = 0 or rr = 7 then pseudo := pseudo || array[sq, rr * 8 + cc, 1, sq, rr * 8 + cc, 2, sq, rr * 8 + cc, 3, sq, rr * 8 + cc, 4];
          else pseudo := pseudo || array[sq, rr * 8 + cc, 0]; end if;
        end if;
      end loop;
    elsif lower(p) = 'n' or lower(p) = 'k' then
      for i in 0..7 loop
        if lower(p) = 'n' then rr := r + kn[i * 2 + 1]; cc := c + kn[i * 2 + 2]; else rr := r + kg[i * 2 + 1]; cc := c + kg[i * 2 + 2]; end if;
        q := _ch_at(b, rr, cc);
        if q = '.' or strpos(theirs, q) > 0 then pseudo := pseudo || array[sq, rr * 8 + cc, 0]; end if;
      end loop;
      if lower(p) = 'k' then   -- キャスリング
        if w and sq = 60 and not _ch_attacked(b, 60, false) then
          if strpos(cas, 'K') > 0 and substr(b, 62, 2) = '..' and substr(b, 64, 1) = 'R' and not _ch_attacked(b, 61, false) and not _ch_attacked(b, 62, false) then pseudo := pseudo || array[60, 62, 0]; end if;
          if strpos(cas, 'Q') > 0 and substr(b, 58, 3) = '...' and substr(b, 57, 1) = 'R' and not _ch_attacked(b, 59, false) and not _ch_attacked(b, 58, false) then pseudo := pseudo || array[60, 58, 0]; end if;
        elsif not w and sq = 4 and not _ch_attacked(b, 4, true) then
          if strpos(cas, 'k') > 0 and substr(b, 6, 2) = '..' and substr(b, 8, 1) = 'r' and not _ch_attacked(b, 5, true) and not _ch_attacked(b, 6, true) then pseudo := pseudo || array[4, 6, 0]; end if;
          if strpos(cas, 'q') > 0 and substr(b, 2, 3) = '...' and substr(b, 1, 1) = 'r' and not _ch_attacked(b, 3, true) and not _ch_attacked(b, 2, true) then pseudo := pseudo || array[4, 2, 0]; end if;
        end if;
      end if;
    else
      for i in 0..7 loop
        continue when lower(p) = 'r' and kg[i * 2 + 1] <> 0 and kg[i * 2 + 2] <> 0;
        continue when lower(p) = 'b' and (kg[i * 2 + 1] = 0 or kg[i * 2 + 2] = 0);
        rr := r + kg[i * 2 + 1]; cc := c + kg[i * 2 + 2];
        loop
          q := _ch_at(b, rr, cc);
          exit when q = '#' or strpos(mine, q) > 0;
          pseudo := pseudo || array[sq, rr * 8 + cc, 0];
          exit when q <> '.';
          rr := rr + kg[i * 2 + 1]; cc := cc + kg[i * 2 + 2];
        end loop;
      end loop;
    end if;
  end loop;
  -- 自分のキングがきかれたままになる手はだめ
  for i in 0..(cardinality(pseudo) / 3 - 1) loop
    nb := _ch_make(b, pseudo[i * 3 + 1], pseudo[i * 3 + 2], (array['q', 'r', 'b', 'n'])[nullif(pseudo[i * 3 + 3], 0)], ep);
    ks := strpos(nb, case when w then 'K' else 'k' end) - 1;
    if not _ch_attacked(nb, ks, not w) then
      res := res || jsonb_build_array(jsonb_build_object('f', pseudo[i * 3 + 1], 't', pseudo[i * 3 + 2])
             || case when pseudo[i * 3 + 3] > 0 then jsonb_build_object('p', (array['q', 'r', 'b', 'n'])[pseudo[i * 3 + 3]]) else '{}'::jsonb end);
    end if;
  end loop;
  return res;
end $$;

create or replace function public._ch_init() returns jsonb
language sql immutable as $$
  select jsonb_build_object('board', 'rnbqkbnr' || 'pppppppp' || repeat('.', 32) || 'PPPPPPPP' || 'RNBQKBNR',
    'castle', 'KQkq', 'ep', -1, 'half', 0, 'rep', '{}'::jsonb, 'check', false,
    'legal', _ch_legal(jsonb_build_object('board', 'rnbqkbnr' || 'pppppppp' || repeat('.', 32) || 'PPPPPPPP' || 'RNBQKBNR', 'castle', 'KQkq', 'ep', -1), true))
$$;

create or replace function public._ch_apply(st jsonb, seat int, mv jsonb) returns jsonb
language plpgsql immutable as $$
declare w boolean := seat = 0; b text := st->>'board'; f int; t int; pr text; ok boolean := false; m jsonb; p text; cap text;
  nb text; cas text := coalesce(st->>'castle', ''); nep int := -1; half int := coalesce((st->>'half')::int, 0) + 1;
  rep jsonb := coalesce(st->'rep', '{}'::jsonb); key text; nlegal jsonb; chk boolean; ns jsonb; mat text;
begin
  f := (mv->>'f')::int; t := (mv->>'t')::int; pr := lower(coalesce(mv->>'p', ''));
  for m in select * from jsonb_array_elements(coalesce(st->'legal', _ch_legal(st, w))) loop
    if (m->>'f')::int = f and (m->>'t')::int = t and coalesce(m->>'p', '') = (case when m ? 'p' then coalesce(nullif(pr, ''), 'q') else '' end) then ok := true; exit; end if;
  end loop;
  if not ok then raise exception 'その手は指せません'; end if;
  p := substr(b, f + 1, 1); cap := substr(b, t + 1, 1);
  nb := _ch_make(b, f, t, nullif(pr, ''), coalesce((st->>'ep')::int, -1));
  if lower(p) = 'p' or cap <> '.' or (lower(p) = 'p' and t = coalesce((st->>'ep')::int, -1)) then half := 0; end if;
  if lower(p) = 'p' and abs(t - f) = 16 then nep := (f + t) / 2; end if;
  -- キャスリングの権利
  if p = 'K' then cas := replace(replace(cas, 'K', ''), 'Q', ''); end if;
  if p = 'k' then cas := replace(replace(cas, 'k', ''), 'q', ''); end if;
  if f = 63 or t = 63 then cas := replace(cas, 'K', ''); end if;
  if f = 56 or t = 56 then cas := replace(cas, 'Q', ''); end if;
  if f = 7 or t = 7 then cas := replace(cas, 'k', ''); end if;
  if f = 0 or t = 0 then cas := replace(cas, 'q', ''); end if;
  key := md5(nb || case when w then 'b' else 'w' end || cas || nep);
  rep := jsonb_set(rep, array[key], to_jsonb(coalesce((rep->>key)::int, 0) + 1));
  ns := jsonb_build_object('board', nb, 'castle', cas, 'ep', nep);
  nlegal := _ch_legal(ns, not w);
  chk := _ch_attacked(nb, strpos(nb, case when w then 'k' else 'K' end) - 1, w);
  ns := ns || jsonb_build_object('half', half, 'rep', rep, 'check', chk, 'last', jsonb_build_array(f, t), 'legal', nlegal, 'next', 1 - seat, 'over', false);
  if jsonb_array_length(nlegal) = 0 then
    if chk then return ns || jsonb_build_object('over', true, 'winner', seat, 'reason', 'チェックメイト'); end if;
    return ns || jsonb_build_object('over', true, 'winner', -1, 'reason', 'ステイルメイト（引き分け）');
  end if;
  if half >= 100 then return ns || jsonb_build_object('over', true, 'winner', -1, 'reason', '50手ルール（引き分け）'); end if;
  if (rep->>key)::int >= 3 then return ns || jsonb_build_object('over', true, 'winner', -1, 'reason', '同じ形が3回（引き分け）'); end if;
  mat := regexp_replace(nb, '[.kK]', '', 'g');
  if mat = '' or mat in ('B', 'b', 'N', 'n') then return ns || jsonb_build_object('over', true, 'winner', -1, 'reason', '駒が足りない（引き分け）'); end if;
  return ns;
end $$;

-- ---------- 将棋（9×9。盤は81文字：先手は大文字、後手は小文字。. は空き。0 番が左上（後手の陣・9一）、80 番が右下（1九）。先手＝席0）
--   駒：K 玉 / R 飛 / B 角 / G 金 / S 銀 / N 桂 / L 香 / P 歩 / D 龍 / H 馬 / V 成銀 / M 成桂 / Y 成香 / T と
--   持ち駒：hand.0（先手）・hand.1（後手）に駒の文字をならべる（例 'PPS'）
--   手：盤の駒を動かす {f, t, pr（成る）} ／ 打つ {d: 駒, t}
create or replace function public._sg_promo(p text) returns text
language sql immutable as $$ select case upper(p) when 'R' then 'D' when 'B' then 'H' when 'S' then 'V' when 'N' then 'M' when 'L' then 'Y' when 'P' then 'T' end $$;
create or replace function public._sg_base(p text) returns text
language sql immutable as $$ select case upper(p) when 'D' then 'R' when 'H' then 'B' when 'V' then 'S' when 'M' then 'N' when 'Y' then 'L' when 'T' then 'P' else upper(p) end $$;

-- 1マスずつ動く向き（先手の向き。dr, dc を2つずつ）
create or replace function public._sg_steps(pu text) returns int[]
language sql immutable as $$
  select case pu
    when 'K' then array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,-1, 1,0, 1,1]
    when 'G' then array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,0]
    when 'V' then array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,0]
    when 'M' then array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,0]
    when 'Y' then array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,0]
    when 'T' then array[-1,-1, -1,0, -1,1, 0,-1, 0,1, 1,0]
    when 'S' then array[-1,-1, -1,0, -1,1, 1,-1, 1,1]
    when 'N' then array[-2,-1, -2,1]
    when 'P' then array[-1,0]
    when 'D' then array[-1,-1, -1,1, 1,-1, 1,1]
    when 'H' then array[-1,0, 1,0, 0,-1, 0,1]
    else '{}'::int[] end
$$;
-- まっすぐ何マスも動く向き
create or replace function public._sg_slides(pu text) returns int[]
language sql immutable as $$
  select case pu
    when 'R' then array[-1,0, 1,0, 0,-1, 0,1]
    when 'D' then array[-1,0, 1,0, 0,-1, 0,1]
    when 'B' then array[-1,-1, -1,1, 1,-1, 1,1]
    when 'H' then array[-1,-1, -1,1, 1,-1, 1,1]
    when 'L' then array[-1,0]
    else '{}'::int[] end
$$;

-- sq が「先手（bys）の駒」にきかれているか
create or replace function public._sg_attacked(b text, sq int, bys boolean) returns boolean
language plpgsql immutable as $$
declare s int; p text; pu text; dr int; dc int; st int[]; sl int[]; i int; rr int; cc int; ok boolean; k int; tr int := sq / 9; tc int := sq % 9;
begin
  for s in 0..80 loop
    p := substr(b, s + 1, 1);
    continue when p = '.' or (bys and p <> upper(p)) or (not bys and p <> lower(p));
    pu := upper(p);
    dr := tr - s / 9; dc := tc - s % 9;
    if not bys then dr := -dr; end if;
    st := _sg_steps(pu);
    for i in 0..(coalesce(cardinality(st), 0) / 2 - 1) loop
      if st[i * 2 + 1] = dr and st[i * 2 + 2] = dc then return true; end if;
    end loop;
    sl := _sg_slides(pu);
    for i in 0..(coalesce(cardinality(sl), 0) / 2 - 1) loop
      -- 向きが合っていて、あいだに駒がない
      if (sl[i * 2 + 1] = sign(dr) and sl[i * 2 + 2] = sign(dc)) and (dr = 0 or dc = 0 or abs(dr) = abs(dc)) and (dr <> 0 or dc <> 0) then
        ok := true;
        for k in 1..(greatest(abs(dr), abs(dc)) - 1) loop
          rr := s / 9 + (case when bys then sign(dr) else -sign(dr) end) * k; cc := s % 9 + sign(dc) * k;
          if substr(b, rr * 9 + cc + 1, 1) <> '.' then ok := false; exit; end if;
        end loop;
        if ok then return true; end if;
      end if;
    end loop;
  end loop;
  return false;
end $$;

-- 手を動かした後の盤と持ち駒
create or replace function public._sg_make(st jsonb, side int, mv jsonb) returns jsonb
language plpgsql immutable as $$
declare b text := st->>'board'; h0 text := coalesce(st->'hand'->>'0', ''); h1 text := coalesce(st->'hand'->>'1', '');
  f int; t int; p text; cap text; d text;
begin
  t := (mv->>'t')::int;
  if mv ? 'd' then
    d := upper(mv->>'d');
    if side = 0 then h0 := regexp_replace(h0, d, ''); b := overlay(b placing d from t + 1 for 1);
    else h1 := regexp_replace(h1, d, ''); b := overlay(b placing lower(d) from t + 1 for 1); end if;
  else
    f := (mv->>'f')::int; p := substr(b, f + 1, 1); cap := substr(b, t + 1, 1);
    if cap <> '.' then
      if side = 0 then h0 := h0 || _sg_base(cap); else h1 := h1 || _sg_base(cap); end if;
    end if;
    if coalesce((mv->>'pr')::boolean, false) then p := case when side = 0 then _sg_promo(p) else lower(_sg_promo(p)) end; end if;
    b := overlay(overlay(b placing '.' from f + 1 for 1) placing p from t + 1 for 1);
  end if;
  return jsonb_build_object('board', b, 'hand', jsonb_build_object('0', h0, '1', h1));
end $$;

-- 指せる手。one = true なら、1つ見つかったらすぐ返す（詰みの判定用）
create or replace function public._sg_legal(st jsonb, side int, one boolean default false) returns jsonb
language plpgsql immutable as $$
declare b text := st->>'board'; hand text := coalesce(st->'hand'->>side::text, ''); res jsonb := '[]'::jsonb;
  sente boolean := side = 0; s int; p text; pu text; r int; c int; i int; k int; st2 int[]; sl int[]; rr int; cc int; t int; q text;
  cand jsonb := '[]'::jsonb; mv jsonb; ns jsonb; nb text; ks int; canpr boolean; mustpr boolean; inz boolean; d text; col int; nifu boolean;
  ek int; ns2 jsonb;
begin
  for s in 0..80 loop
    p := substr(b, s + 1, 1);
    continue when p = '.' or (sente and p <> upper(p)) or (not sente and p <> lower(p));
    pu := upper(p); r := s / 9; c := s % 9;
    st2 := _sg_steps(pu); sl := _sg_slides(pu);
    -- 1マス・桂馬
    for i in 0..(coalesce(cardinality(st2), 0) / 2 - 1) loop
      rr := r + case when sente then st2[i * 2 + 1] else -st2[i * 2 + 1] end; cc := c + st2[i * 2 + 2];
      continue when rr < 0 or rr > 8 or cc < 0 or cc > 8;
      q := substr(b, rr * 9 + cc + 1, 1);
      continue when q <> '.' and ((sente and q = upper(q)) or (not sente and q = lower(q)));
      cand := cand || jsonb_build_array(jsonb_build_array(s, rr * 9 + cc));
    end loop;
    -- 飛・角・香（龍・馬）
    for i in 0..(coalesce(cardinality(sl), 0) / 2 - 1) loop
      rr := r; cc := c;
      loop
        rr := rr + case when sente then sl[i * 2 + 1] else -sl[i * 2 + 1] end; cc := cc + sl[i * 2 + 2];
        exit when rr < 0 or rr > 8 or cc < 0 or cc > 8;
        q := substr(b, rr * 9 + cc + 1, 1);
        exit when q <> '.' and ((sente and q = upper(q)) or (not sente and q = lower(q)));
        cand := cand || jsonb_build_array(jsonb_build_array(s, rr * 9 + cc));
        exit when q <> '.';
      end loop;
    end loop;
  end loop;
  -- 成り・成らず
  for mv in select * from jsonb_array_elements(cand) loop
    s := (mv->>0)::int; t := (mv->>1)::int; p := substr(b, s + 1, 1); pu := upper(p);
    canpr := pu in ('R', 'B', 'S', 'N', 'L', 'P') and (case when sente then s / 9 <= 2 or t / 9 <= 2 else s / 9 >= 6 or t / 9 >= 6 end);
    mustpr := case when sente then (pu in ('P', 'L') and t / 9 = 0) or (pu = 'N' and t / 9 <= 1)
                   else (pu in ('P', 'L') and t / 9 = 8) or (pu = 'N' and t / 9 >= 7) end;
    foreach k in array case when mustpr then array[1] when canpr then array[0, 1] else array[0] end loop
      ns := _sg_make(st, side, jsonb_build_object('f', s, 't', t, 'pr', k = 1));
      nb := ns->>'board'; ks := strpos(nb, case when sente then 'K' else 'k' end) - 1;
      if ks < 0 or not _sg_attacked(nb, ks, not sente) then
        res := res || jsonb_build_array(jsonb_build_object('f', s, 't', t, 'pr', k = 1));
        if one then return res; end if;
      end if;
    end loop;
  end loop;
  -- 打つ
  foreach d in array array['R', 'B', 'G', 'S', 'N', 'L', 'P'] loop
    continue when strpos(hand, d) = 0;
    for t in 0..80 loop
      continue when substr(b, t + 1, 1) <> '.';
      r := t / 9;
      continue when d in ('P', 'L') and r = (case when sente then 0 else 8 end);
      continue when d = 'N' and (case when sente then r <= 1 else r >= 7 end);
      if d = 'P' then   -- 二歩
        col := t % 9; nifu := false;
        for k in 0..8 loop
          if substr(b, k * 9 + col + 1, 1) = (case when sente then 'P' else 'p' end) then nifu := true; exit; end if;
        end loop;
        continue when nifu;
      end if;
      ns := _sg_make(st, side, jsonb_build_object('d', d, 't', t));
      nb := ns->>'board'; ks := strpos(nb, case when sente then 'K' else 'k' end) - 1;
      continue when ks >= 0 and _sg_attacked(nb, ks, not sente);
      if d = 'P' then   -- 打ち歩詰め
        ek := strpos(nb, case when sente then 'k' else 'K' end) - 1;
        if ek >= 0 and _sg_attacked(nb, ek, sente) then
          ns2 := _sg_legal(ns, 1 - side, true);
          continue when jsonb_array_length(ns2) = 0;
        end if;
      end if;
      res := res || jsonb_build_array(jsonb_build_object('d', d, 't', t));
      if one then return res; end if;
    end loop;
  end loop;
  return res;
end $$;

create or replace function public._sg_init() returns jsonb
language plpgsql immutable as $$
declare b text := 'lnsgkgsnl' || '.r.....b.' || 'ppppppppp' || repeat('.', 27) || 'PPPPPPPPP' || '.B.....R.' || 'LNSGKGSNL'; st jsonb;
begin
  st := jsonb_build_object('board', b, 'hand', jsonb_build_object('0', '', '1', ''), 'rep', '{}'::jsonb, 'check', false);
  return st || jsonb_build_object('legal', _sg_legal(st, 0));
end $$;

create or replace function public._sg_apply(st jsonb, seat int, mv jsonb) returns jsonb
language plpgsql immutable as $$
declare ok boolean := false; m jsonb; ns jsonb; nb text; rep jsonb := coalesce(st->'rep', '{}'::jsonb); key text; nlegal jsonb; chk boolean; ek int;
  h0 text; h1 text; norm jsonb;
begin
  if mv ? 'd' then norm := jsonb_build_object('d', upper(mv->>'d'), 't', (mv->>'t')::int);
  else norm := jsonb_build_object('f', (mv->>'f')::int, 't', (mv->>'t')::int, 'pr', coalesce((mv->>'pr')::boolean, false)); end if;
  for m in select * from jsonb_array_elements(coalesce(st->'legal', _sg_legal(st, seat))) loop
    if m = norm then ok := true; exit; end if;
  end loop;
  if not ok then raise exception 'その手は指せません'; end if;
  ns := _sg_make(st, seat, norm);
  nb := ns->>'board';
  h0 := (select string_agg(x, '' order by x) from regexp_split_to_table(ns->'hand'->>'0', '') x);
  h1 := (select string_agg(x, '' order by x) from regexp_split_to_table(ns->'hand'->>'1', '') x);
  ns := jsonb_build_object('board', nb, 'hand', jsonb_build_object('0', coalesce(h0, ''), '1', coalesce(h1, '')));
  key := md5(nb || '|' || coalesce(h0, '') || '|' || coalesce(h1, '') || '|' || (1 - seat));
  rep := jsonb_set(rep, array[key], to_jsonb(coalesce((rep->>key)::int, 0) + 1));
  nlegal := _sg_legal(ns, 1 - seat);
  ek := strpos(nb, case when seat = 0 then 'k' else 'K' end) - 1;
  chk := ek >= 0 and _sg_attacked(nb, ek, seat = 0);
  ns := ns || jsonb_build_object('rep', rep, 'check', chk, 'last', norm->'t', 'lastmv', norm, 'legal', nlegal, 'next', 1 - seat, 'over', false);
  if jsonb_array_length(nlegal) = 0 then return ns || jsonb_build_object('over', true, 'winner', seat, 'reason', '詰み'); end if;
  if (rep->>key)::int >= 4 then return ns || jsonb_build_object('over', true, 'winner', -1, 'reason', '千日手（引き分け）'); end if;
  return ns;
end $$;

-- ---------- ゲームごとの入り口 ----------
create or replace function public._game_init(g text) returns jsonb
language plpgsql immutable as $$
begin
  if g = 'reversi' then
    return jsonb_build_object('board', repeat('.', 27) || 'WB' || repeat('.', 6) || 'BW' || repeat('.', 27), 'black', 2, 'white', 2);
  end if;
  if g = 'chess' then return _ch_init(); end if;
  if g = 'shogi' then return _sg_init(); end if;
  raise exception 'そのゲームはまだ遊べません';
end $$;

create or replace function public._game_legal(g text, st jsonb, seat int) returns jsonb
language plpgsql immutable as $$
begin
  if g = 'reversi' then return to_jsonb(_rv_legal(st->>'board', case seat when 0 then 'B' else 'W' end)); end if;
  if g in ('chess', 'shogi') then return coalesce(st->'legal', '[]'::jsonb); end if;
  return '[]'::jsonb;
end $$;

create or replace function public._game_apply(g text, st jsonb, seat int, mv jsonb) returns jsonb
language plpgsql immutable as $$
begin
  if g = 'reversi' then return _rv_apply(st, seat, mv); end if;
  if g = 'chess' then return _ch_apply(st, seat, mv); end if;
  if g = 'shogi' then return _sg_apply(st, seat, mv); end if;
  raise exception 'そのゲームはまだ遊べません';
end $$;

create or replace function public._game_name(g text) returns text
language sql immutable as $$ select case g when 'reversi' then 'リバーシ' when 'chess' then 'チェス' when 'shogi' then '将棋' else g end $$;

-- 終わり：賭けの精算（山分け・国庫5%）
create or replace function public._room_finish(rid bigint, w int, why text) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; pool bigint; win_pool bigint; cut bigint; b record; pay bigint; paid bigint := 0; last_id bigint;
begin
  select * into r from game_rooms where id = rid for update;
  if r.status <> 'playing' then return; end if;
  update game_rooms set status = 'finished', winner = w, reason = why, finished_at = _now() where id = rid;
  pool := coalesce((select sum(amount) from game_bets where room_id = rid), 0);
  win_pool := coalesce((select sum(amount) from game_bets where room_id = rid and seat = w), 0);
  if pool = 0 then return; end if;
  if w is null or w < 0 or win_pool = 0 or win_pool = pool then
    -- 引き分け・勝った側に賭けがない・片方にしか賭けがない → 全部返す
    for b in select * from game_bets where room_id = rid loop
      update profiles set balance = balance + b.amount where id = b.user_id;
      update game_bets set payout = b.amount where id = b.id;
      perform _log(b.user_id, 'game_bet', b.amount, b.amount, jsonb_build_object('room', rid, 'refund', true));
    end loop;
    return;
  end if;
  cut := floor(pool * 0.05);
  select max(id) into last_id from game_bets where room_id = rid and seat = w;
  for b in select * from game_bets where room_id = rid order by id loop
    if b.seat = w then
      pay := floor((pool - cut)::numeric * b.amount / win_pool);
      if b.id = last_id then pay := pay + (pool - cut - paid - pay); end if;   -- 端数は最後の人に
      paid := paid + pay;
      perform _give(b.user_id, pay);
    else
      pay := 0;
    end if;
    update game_bets set payout = pay where id = b.id;
    perform _log(b.user_id, 'game_bet', b.amount, pay, jsonb_build_object('room', rid));
  end loop;
  update treasury set balance = balance + cut, casino_total = casino_total + cut where id = 1;
end $$;

-- 持ち時間が切れていないか見る（切れていたら負け）
create or replace function public._room_tick(rid bigint) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; used int;
begin
  select * into r from game_rooms where id = rid;
  if r.status <> 'playing' or r.turn_at is null then return; end if;
  used := floor(extract(epoch from (_now() - r.turn_at)) * 1000);
  if used >= r.clock_ms[r.turn + 1] then
    update game_rooms set clock_ms[r.turn + 1] = 0 where id = rid;
    perform _room_finish(rid, 1 - r.turn, '時間切れ');
  end if;
end $$;

create or replace function public._room_json(r game_rooms, u uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare me int; used int := 0; clocks int[] := r.clock_ms;
begin
  me := case when r.seats[1] = u then 0 when r.seats[2] = u then 1 else null end;
  if r.status = 'playing' and r.turn_at is not null then
    used := floor(extract(epoch from (_now() - r.turn_at)) * 1000);
    clocks[r.turn + 1] := greatest(clocks[r.turn + 1] - used, 0);
  end if;
  return jsonb_build_object('id', r.id, 'game', r.game, 'game_name', _game_name(r.game), 'title', r.title, 'status', r.status,
    'host', (select nickname from profiles where id = r.host), 'host_badge', _badge(r.host), 'mine_host', r.host = u,
    'invite', (select account_no from profiles where id = r.invite), 'invited_me', r.invite = u,
    'players', (select coalesce(jsonb_agg(jsonb_build_object('seat', s.n - 1, 'nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id)) order by s.n), '[]'::jsonb)
                  from unnest(r.seats) with ordinality s(uid, n) join profiles p on p.id = s.uid),
    'me', me, 'time_ms', r.time_ms, 'clock_ms', to_jsonb(clocks), 'turn', r.turn, 'move_no', r.move_no,
    'state', r.state - 'rep' - 'legal', 'winner', r.winner, 'reason', r.reason, 'bets_on', r.bets_on, 'draw_offer', r.draw_offer,
    'bet_open', r.bets_on and r.status in ('waiting', 'playing') and r.move_no < 10,
    'legal', case when r.status = 'playing' and me = r.turn then _game_legal(r.game, r.state, me) else '[]'::jsonb end,
    'at', _dlabel(r.created_at));
end $$;

-- 部屋の一覧（えらんだゲーム。待っている部屋・対局中・自分の部屋）
create or replace function public.room_list(p_game text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r record;
begin
  -- 1日たっても始まらない部屋は片づける
  update game_rooms set status = 'canceled', finished_at = _now() where status = 'waiting' and created_at < _now() - interval '1 day';
  for r in select id from game_rooms where status = 'playing' and game = p_game loop perform _room_tick(r.id); end loop;
  return jsonb_build_object(
    'waiting', (select coalesce(jsonb_agg(_room_json(g, u) order by g.id desc), '[]'::jsonb) from (
                 select * from game_rooms where game = p_game and status = 'waiting' and (invite is null or invite = u or host = u)
                  order by id desc limit 30) g),
    'playing', (select coalesce(jsonb_agg(_room_json(g, u) || jsonb_build_object(
                   'pool', (select coalesce(sum(amount), 0) from game_bets where room_id = g.id)) order by g.id desc), '[]'::jsonb) from (
                 select * from game_rooms where game = p_game and status = 'playing' order by id desc limit 30) g),
    'finished', (select coalesce(jsonb_agg(_room_json(g, u) order by g.finished_at desc), '[]'::jsonb) from (
                 select * from game_rooms where game = p_game and status = 'finished' and u = any(seats) order by finished_at desc limit 10) g));
end $$;

-- 部屋を作る
create or replace function public.room_create(p_game text, p_title text, p_time_min int, p_invite text, p_bets boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); inv uuid; rid bigint;
begin
  if p_game not in ('reversi', 'chess', 'shogi') then raise exception 'そのゲームはまだ遊べません'; end if;
  if p_time_min is null or p_time_min < 1 or p_time_min > 180 then raise exception '持ち時間は1〜180分（3時間）です'; end if;
  if (select count(*) from game_rooms where host = u and status = 'waiting') >= 3 then raise exception '待っている部屋は3つまでです'; end if;
  if coalesce(btrim(p_invite), '') <> '' then
    select id into inv from profiles where account_no = btrim(p_invite);
    if inv is null then raise exception '招待する人のIDが見つかりません'; end if;
    if inv = u then raise exception '自分は招待できません'; end if;
  end if;
  insert into game_rooms(game, title, host, invite, seats, time_ms, bets_on, created_at)
  values (p_game, left(btrim(coalesce(p_title, '')), 30), u, inv, array[u], p_time_min * 60000, coalesce(p_bets, true), _now())
  returning id into rid;
  if inv is not null then
    perform _notice(inv, format('【対戦】%s さんから%sの対戦に招待されました。遊戯タブの%sから入れます（部屋 #%s）。',
                    (select nickname from profiles where id = u), _game_name(p_game), _game_name(p_game), rid));
  end if;
  return room_state(rid);
end $$;

-- 部屋に入る（ふたりそろったら始まる）
create or replace function public.room_join(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r game_rooms; s uuid[];
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'waiting' then raise exception 'この部屋にはもう入れません'; end if;
  if u = any(r.seats) then raise exception 'もう入っています'; end if;
  if r.invite is not null and r.invite <> u then raise exception 'この部屋は招待された人だけです'; end if;
  if exists (select 1 from game_bets where room_id = r.id and user_id = u) then raise exception 'この部屋に賭けているので、対局はできません'; end if;
  s := r.seats || u;
  if random() < 0.5 then s := array[s[2], s[1]]; end if;   -- 先手・後手はランダム
  update game_rooms set seats = s, status = 'playing', started_at = _now(), turn = 0, turn_at = _now(), move_no = 0,
         clock_ms = array[r.time_ms, r.time_ms], state = _game_init(r.game)
   where id = r.id;
  perform _notice(r.host, format('【対戦】%s さんが部屋 #%s に入りました。対局が始まります。', (select nickname from profiles where id = u), r.id));
  return room_state(r.id);
end $$;

-- 部屋を出る（始まる前だけ。主催が出ると部屋はなくなる。賭けは返す）
create or replace function public.room_leave(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r game_rooms; b record;
begin
  select * into r from game_rooms where id = p_room and status = 'waiting' and host = u for update;
  if not found then raise exception '出られる部屋が見つかりません（始まったあとは「投了」してください）'; end if;
  update game_rooms set status = 'canceled', finished_at = _now() where id = r.id;
  for b in select * from game_bets where room_id = r.id loop
    update profiles set balance = balance + b.amount where id = b.user_id;
    update game_bets set payout = b.amount where id = b.id;
    perform _log(b.user_id, 'game_bet', b.amount, b.amount, jsonb_build_object('room', r.id, 'refund', true));
  end loop;
  return room_list(r.game);
end $$;

-- 部屋のようす（観戦もこれ）
create or replace function public.room_state(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r game_rooms;
begin
  perform _room_tick(p_room);
  select * into r from game_rooms where id = p_room;
  if not found then raise exception '部屋が見つかりません'; end if;
  return _room_json(r, u) || jsonb_build_object(
    'moves', (select coalesce(jsonb_agg(jsonb_build_object('n', n, 'seat', seat, 'move', move) order by n), '[]'::jsonb) from game_moves where room_id = r.id),
    'pool', (select coalesce(jsonb_agg(jsonb_build_object('seat', seat, 'amount', a, 'people', c) order by seat), '[]'::jsonb) from (
              select seat, sum(amount) a, count(distinct user_id) c from game_bets where room_id = r.id group by seat) z),
    'my_bets', (select coalesce(jsonb_agg(jsonb_build_object('seat', seat, 'amount', amount, 'payout', payout) order by id), '[]'::jsonb)
                  from game_bets where room_id = r.id and user_id = u),
    'chat', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'nickname', p.nickname, 'badge', _badge(p.id), 'body', z.body,
               'ts', _kb_ms(z.at), 'player', z.user_id = any(r.seats)) order by z.id), '[]'::jsonb) from (
              select * from game_chat where room_id = r.id order by id desc limit 40) z join profiles p on p.id = z.user_id),
    'now_ms', _kb_ms(_now()), 'balance', _bal(u));
end $$;

-- 手を指す
create or replace function public.room_move(p_room bigint, p_move jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r game_rooms; me int; used int; ns jsonb; left_ms int;
begin
  perform _room_tick(p_room);
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'playing' then raise exception 'この対局はもう終わっています'; end if;
  me := case when r.seats[1] = u then 0 when r.seats[2] = u then 1 else null end;
  if me is null then raise exception 'あなたは対局していません'; end if;
  if me <> r.turn then raise exception 'いまは相手の番です'; end if;
  used := floor(extract(epoch from (_now() - r.turn_at)) * 1000);
  left_ms := greatest(r.clock_ms[me + 1] - used, 0);
  ns := _game_apply(r.game, r.state, me, p_move);
  insert into game_moves(room_id, n, seat, move, at) values (r.id, r.move_no + 1, me, p_move, _now());
  update game_rooms set state = ns, move_no = move_no + 1, clock_ms[me + 1] = left_ms, draw_offer = null,
         turn = coalesce((ns->>'next')::int, turn), turn_at = _now()
   where id = r.id;
  if (ns->>'over')::boolean then perform _room_finish(r.id, (ns->>'winner')::int, ns->>'reason'); end if;
  return room_state(r.id);
end $$;

-- 投了
create or replace function public.room_resign(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r game_rooms; me int;
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'playing' then raise exception 'この対局はもう終わっています'; end if;
  me := case when r.seats[1] = u then 0 when r.seats[2] = u then 1 else null end;
  if me is null then raise exception 'あなたは対局していません'; end if;
  perform _room_finish(r.id, 1 - me, '投了');
  return room_state(r.id);
end $$;

-- 引き分けの申し出（offer）・受ける（accept）・断る／取り消す（decline）
create or replace function public.room_draw(p_room bigint, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r game_rooms; me int;
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'playing' then raise exception 'この対局はもう終わっています'; end if;
  me := case when r.seats[1] = u then 0 when r.seats[2] = u then 1 else null end;
  if me is null then raise exception 'あなたは対局していません'; end if;
  if p_action = 'offer' then
    update game_rooms set draw_offer = me where id = r.id;
  elsif p_action = 'accept' then
    if r.draw_offer is null or r.draw_offer = me then raise exception '相手からの申し出がありません'; end if;
    update game_rooms set draw_offer = null where id = r.id;
    perform _room_finish(r.id, -1, '合意の引き分け');
  else
    update game_rooms set draw_offer = null where id = r.id;
  end if;
  return room_state(r.id);
end $$;

-- 観戦して賭ける（勝つと思う席に）
create or replace function public.room_bet(p_room bigint, p_seat int, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r game_rooms;
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status not in ('waiting', 'playing') then raise exception 'この対局にはもう賭けられません'; end if;
  if not r.bets_on then raise exception 'この部屋は賭けなしです'; end if;
  if r.move_no >= 10 then raise exception '賭けは10手目までです'; end if;
  if u = any(r.seats) then raise exception '対局している本人は賭けられません'; end if;
  if r.status = 'waiting' then raise exception '対局が始まってから賭けられます（先手・後手が決まってから）'; end if;
  if p_seat not in (0, 1) then raise exception '賭ける側をえらんでください'; end if;
  if exists (select 1 from game_bets where room_id = r.id and user_id = u and seat <> p_seat) then raise exception '両方には賭けられません'; end if;
  if p_amount is null or p_amount < 1 then raise exception '1 X以上にしてください'; end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので賭けられません'; end if;
  perform _take(u, p_amount);
  insert into game_bets(room_id, user_id, seat, amount, at) values (r.id, u, p_seat, p_amount, _now());
  return room_state(r.id);
end $$;

-- チャット（10秒に1回・100文字まで）
create or replace function public.room_chat(p_room bigint, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); b text := btrim(coalesce(p_body, ''));
begin
  if not exists (select 1 from game_rooms where id = p_room) then raise exception '部屋が見つかりません'; end if;
  if char_length(b) < 1 then raise exception '何か書いてください'; end if;
  if char_length(b) > 100 then raise exception '100文字までです'; end if;
  if exists (select 1 from game_chat where user_id = u and at > _now() - interval '10 seconds') then raise exception '送るのは10秒に1回までです'; end if;
  insert into game_chat(room_id, user_id, body, at) values (p_room, u, b, _now());
  return room_state(p_room);
end $$;

-- ---------------------------------------------------------------------
-- 広報・書籍（情報タブ）
--   新聞：会社が出す。記事を書き、購読料（期間ごと）を決める（0なら無料）。無料の記事は「ニュース」に出る
--   本　：だれでも書ける（個人・会社）。値段を決める（0なら無料）。章ごとに書き、試し読み（無料の章）も作れる
--   買う・購読する：代金（＋手数料1%・最低1 Xは国庫へ）。代金は書いた人（会社なら会社）に入る。個人の売上は所得
--   管理者・副管理者は、ふさわしくないものを非公開にできる
-- ---------------------------------------------------------------------
create table if not exists public.pubs (
  id          bigserial primary key,
  kind        text not null check (kind in ('paper', 'book')),
  author      uuid references public.profiles(id) on delete cascade,     -- 個人の本
  company_id  int references public.companies(id) on delete cascade,     -- 会社の新聞・本
  title       text not null,
  description text not null default '',
  price       bigint not null default 0 check (price >= 0),             -- 本：買う値段／新聞：購読料（1期間）
  period_days int not null default 30,
  status      text not null default 'active',                           -- active / hidden
  reason      text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table if not exists public.pub_items (
  id         bigserial primary key,
  pub_id     bigint not null references public.pubs(id) on delete cascade,
  title      text not null,
  body       text not null,
  free       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists pub_items_pub_idx on public.pub_items(pub_id, id);
create index if not exists pub_items_news_idx on public.pub_items(free, id desc);
create table if not exists public.pub_access (
  pub_id  bigint not null references public.pubs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  until   timestamptz,                                  -- null＝ずっと（本）
  primary key (pub_id, user_id)
);
alter table public.pubs enable row level security;
alter table public.pub_items enable row level security;
alter table public.pub_access enable row level security;
revoke all on public.pubs, public.pub_items, public.pub_access from anon, authenticated;

-- 書いた人・会社が自分か
create or replace function public._pub_mine(p pubs, u uuid) returns boolean
language sql stable set search_path = public as $$
  select coalesce(p.author = u, false) or exists (select 1 from companies c where c.id = p.company_id and c.owner = u)
$$;

-- 読めるか（無料・買った・購読中・自分のもの）
create or replace function public._pub_can_read(p pubs, u uuid) returns boolean
language sql stable set search_path = public as $$
  select coalesce(p.price = 0 or _pub_mine(p, u)
      or exists (select 1 from pub_access a where a.pub_id = p.id and a.user_id = u and (a.until is null or a.until > _now())), false)
$$;

create or replace function public._pub_json(p pubs, u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', p.id, 'kind', p.kind, 'title', p.title, 'description', p.description, 'price', p.price,
    'period_days', p.period_days, 'status', p.status, 'reason', p.reason, 'updated', _dlabel(p.updated_at),
    'by', coalesce((select name from companies where id = p.company_id), (select nickname from profiles where id = p.author)),
    'by_company', p.company_id is not null, 'by_cid', (select cid from companies where id = p.company_id),
    'by_badge', case when p.company_id is null then _badge(p.author) end,
    'official', coalesce((select official from companies where id = p.company_id), false),
    'items', (select count(*) from pub_items where pub_id = p.id),
    'mine', _pub_mine(p, u), 'can_read', _pub_can_read(p, u),
    'until', (select case when until is null then null else _dlabel(until) end from pub_access where pub_id = p.id and user_id = u and (until is null or until > _now())),
    'owned', exists (select 1 from pub_access where pub_id = p.id and user_id = u and (until is null or until > _now())))
$$;

-- 一覧（新聞・本）
create or replace function public.pub_list(p_kind text, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); q text := btrim(coalesce(p_q, ''));
begin
  return (select coalesce(jsonb_agg(_pub_json(p, u) order by p.updated_at desc), '[]'::jsonb) from (
    select * from pubs p where p.kind = p_kind and (p.status = 'active' or _pub_mine(p, u))
       and (p.company_id is null or exists (select 1 from companies c where c.id = p.company_id and c.status in ('active', 'suspended')))
       and (q = '' or p.title ilike '%' || q || '%' or p.description ilike '%' || q || '%')
     order by p.updated_at desc limit 50) p);
end $$;

-- ニュース（新聞の無料の記事）
create or replace function public.news_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title, 'pub_id', p.id, 'paper', p.title,
            'by', (select name from companies where id = p.company_id), 'official', coalesce((select official from companies where id = p.company_id), false),
            'at', _dlabel(i.created_at), 'head', left(regexp_replace(i.body, '\s+', ' ', 'g'), 60)) order by i.id desc), '[]'::jsonb)
    from (select * from pub_items where free order by id desc limit 200) i join pubs p on p.id = i.pub_id
   where p.kind = 'paper' and p.status = 'active'
     and exists (select 1 from companies c where c.id = p.company_id and c.status in ('active', 'suspended')));
end $$;

-- 新聞・本のページ（記事・章の一覧）
create or replace function public.pub_page(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); p pubs; rd boolean;
begin
  select * into p from pubs where id = p_id;
  if not found or (p.status <> 'active' and not _pub_mine(p, u) and not _is_staff(u)) then raise exception '見つかりません'; end if;
  rd := _pub_can_read(p, u);
  return _pub_json(p, u) || jsonb_build_object('staff', _is_staff(u),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title, 'free', i.free, 'at', _dlabel(i.created_at),
               'chars', char_length(i.body), 'readable', rd or i.free) order by case when p.kind = 'paper' then -i.id else i.id end), '[]'::jsonb)
             from pub_items i where i.pub_id = p.id),
    'balance', _bal(u));
end $$;

-- 読む
create or replace function public.pub_read(p_item bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); i pub_items; p pubs;
begin
  select * into i from pub_items where id = p_item;
  if not found then raise exception '見つかりません'; end if;
  select * into p from pubs where id = i.pub_id;
  if p.status <> 'active' and not _pub_mine(p, u) and not _is_staff(u) then raise exception '見つかりません'; end if;
  if not i.free and not _pub_can_read(p, u) and not _is_staff(u) then
    raise exception '%', case when p.kind = 'paper' then '購読すると読めます' else '買うと読めます' end;
  end if;
  return jsonb_build_object('id', i.id, 'title', i.title, 'body', i.body, 'at', _dlabel(i.created_at), 'free', i.free,
    'pub', _pub_json(p, u),
    'prev', (select id from pub_items where pub_id = p.id and id < i.id order by id desc limit 1),
    'next', (select id from pub_items where pub_id = p.id and id > i.id order by id limit 1));
end $$;

-- 買う（本）・購読する（新聞。期間をのばす）
create or replace function public.pub_buy(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); p pubs; me profiles; fee bigint; c companies; cur timestamptz;
begin
  select * into p from pubs where id = p_id and status = 'active';
  if not found then raise exception '見つかりません'; end if;
  if _pub_mine(p, u) then raise exception '自分のものは買えません'; end if;
  if p.price = 0 then raise exception '無料なので、そのまま読めます'; end if;
  if p.kind = 'book' and exists (select 1 from pub_access where pub_id = p.id and user_id = u) then raise exception 'もう買っています'; end if;
  select * into me from profiles where id = u for update;
  if _now() < me.created_at + interval '7 days' then raise exception '登録から7日たつまで、買い物はできません'; end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので買えません'; end if;
  if p.company_id is not null then
    select * into c from companies where id = p.company_id and status = 'active';
    if not found then raise exception 'この会社はいま営業していません'; end if;
  end if;
  fee := _xfer_fee(p.price);
  if me.balance < p.price + fee then raise exception 'AiliNaXが足りません（手数料 % X をふくめて % X 必要です）', fee, p.price + fee; end if;
  update profiles set balance = balance - (p.price + fee) where id = u;
  update treasury set balance = balance + fee, fee_total = fee_total + fee where id = 1;
  perform _log(u, 'pub_buy', p.price + fee, 0, jsonb_build_object('pub', p.id, 'title', p.title));
  if p.company_id is not null then
    perform _corp_move(p.company_id, p.price, 'pub', format('「%s」の%s（%s さん）', p.title, case when p.kind = 'paper' then '購読料' else '売上' end, me.nickname));
  else
    perform _give(p.author, p.price);
    perform _log(p.author, 'pub_sale', 0, p.price, jsonb_build_object('pub', p.id, 'title', p.title));
    perform _notice(p.author, format('【本】%s さんが「%s」を %s X で買いました。', me.nickname, p.title, _fmt(p.price)));
  end if;
  if p.kind = 'book' then
    insert into pub_access(pub_id, user_id, until) values (p.id, u, null);
  else
    select until into cur from pub_access where pub_id = p.id and user_id = u;
    insert into pub_access(pub_id, user_id, until) values (p.id, u, greatest(coalesce(cur, _now()), _now()) + make_interval(days => p.period_days))
    on conflict (pub_id, user_id) do update set until = excluded.until;
  end if;
  return pub_page(p.id);
end $$;

-- 書く：新聞・本を作る／変える（p_cid：会社として出すときの会社ID。新聞は会社だけ）
create or replace function public.pub_save(p_id bigint, p_kind text, p_cid text, p_title text, p_desc text, p_price bigint, p_period int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); p pubs; c companies; t text := btrim(coalesce(p_title, '')); nid bigint;
begin
  if char_length(t) < 1 or char_length(t) > 40 then raise exception '名前（タイトル）は1〜40文字です'; end if;
  if p_price is null or p_price < 0 or p_price > 1000000000 then raise exception '値段は0〜10億 X です'; end if;
  if p_id is null then
    if p_kind not in ('paper', 'book') then raise exception '新聞か本をえらんでください'; end if;
    if coalesce(btrim(p_cid), '') <> '' then
      c := _my_corp(u, p_cid);
      if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません'; end if;
    elsif p_kind = 'paper' then raise exception '新聞は会社から出します（会社をえらんでください）';
    end if;
    if p_kind = 'paper' and (select count(*) from pubs where company_id = c.id and kind = 'paper') >= 3 then raise exception '新聞は1社3つまでです'; end if;
    if p_kind = 'book' and (select count(*) from pubs where author = u) >= 30 then raise exception '本は30冊までです'; end if;
    insert into pubs(kind, author, company_id, title, description, price, period_days, created_at, updated_at)
    values (p_kind, case when c.id is null then u end, c.id, t, left(coalesce(p_desc, ''), 1000), p_price,
            greatest(1, least(coalesce(p_period, 30), 365)), _now(), _now()) returning id into nid;
    return pub_page(nid);
  end if;
  select * into p from pubs where id = p_id;
  if not found or not _pub_mine(p, u) then raise exception '自分のものではありません'; end if;
  update pubs set title = t, description = left(coalesce(p_desc, ''), 1000), price = p_price,
         period_days = greatest(1, least(coalesce(p_period, period_days), 365)), updated_at = _now()
   where id = p.id;
  return pub_page(p.id);
end $$;

-- 書く：記事・章（10秒に1回）
create or replace function public.pub_item_save(p_pub bigint, p_item bigint, p_title text, p_body text, p_free boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); p pubs; t text := btrim(coalesce(p_title, '')); b text := coalesce(p_body, '');
begin
  select * into p from pubs where id = p_pub;
  if not found or not _pub_mine(p, u) then raise exception '自分のものではありません'; end if;
  if char_length(t) < 1 or char_length(t) > 60 then raise exception 'タイトルは1〜60文字です'; end if;
  if char_length(btrim(b)) < 1 then raise exception '本文を書いてください'; end if;
  if char_length(b) > 20000 then raise exception '本文は2万文字までです（長いときは分けてください）'; end if;
  if p_item is null then
    if exists (select 1 from pub_items i join pubs x on x.id = i.pub_id where _pub_mine(x, u) and i.created_at > _now() - interval '10 seconds') then
      raise exception '続けて出すのは10秒あけてください';
    end if;
    if (select count(*) from pub_items where pub_id = p.id) >= 500 then raise exception '記事・章は500までです'; end if;
    insert into pub_items(pub_id, title, body, free, created_at) values (p.id, t, b, coalesce(p_free, false), _now());
  else
    update pub_items set title = t, body = b, free = coalesce(p_free, free) where id = p_item and pub_id = p.id;
    if not found then raise exception '見つかりません'; end if;
  end if;
  update pubs set updated_at = _now() where id = p.id;
  return pub_page(p.id);
end $$;

create or replace function public.pub_item_delete(p_item bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); i pub_items; p pubs;
begin
  select * into i from pub_items where id = p_item;
  if not found then raise exception '見つかりません'; end if;
  select * into p from pubs where id = i.pub_id;
  if not _pub_mine(p, u) and not _is_staff(u) then raise exception '自分のものではありません'; end if;
  delete from pub_items where id = i.id;
  return pub_page(p.id);
end $$;

-- 自分の本棚（買った本・購読中の新聞）と、書いているもの
create or replace function public.my_pubs() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  return jsonb_build_object(
    'library', (select coalesce(jsonb_agg(_pub_json(p, u) order by p.updated_at desc), '[]'::jsonb)
                  from pubs p join pub_access a on a.pub_id = p.id and a.user_id = u where a.until is null or a.until > _now()),
    'mine', (select coalesce(jsonb_agg(_pub_json(p, u) order by p.updated_at desc), '[]'::jsonb) from pubs p where _pub_mine(p, u)),
    'corps', (select coalesce(jsonb_agg(jsonb_build_object('cid', cid, 'name', name) order by id), '[]'::jsonb)
                from companies where owner = u and status in ('active', 'suspended')));
end $$;

-- 管理者・副管理者：非公開にする・もどす
create or replace function public.admin_pub_hide(p_id bigint, p_hide boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); p pubs; owner_u uuid;
begin
  if not _is_staff(u) then raise exception '管理者だけが使えます'; end if;
  select * into p from pubs where id = p_id for update;
  if not found then raise exception '見つかりません'; end if;
  update pubs set status = case when p_hide then 'hidden' else 'active' end, reason = case when p_hide then left(coalesce(p_reason, ''), 200) end where id = p.id;
  owner_u := coalesce(p.author, (select owner from companies where id = p.company_id));
  perform _notice(owner_u, format('【広報・書籍】「%s」は管理者によって%s。%s', p.title, case when p_hide then '非公開になりました' else '公開にもどりました' end,
                  case when p_hide and coalesce(p_reason, '') <> '' then '理由：' || p_reason else '' end));
  return pub_page(p.id);
end $$;

-- 前の5けたの会社IDを、3けたの会社番号に変える（何度流しても同じ）
do $$
declare r record; nc text;
begin
  for r in select * from public.companies where cid ~ '^\d{5,6}$' and status <> 'rejected' order by id loop
    nc := public._new_ccode();
    update public.tx_log set detail = detail - 'cid' || jsonb_build_object('company_id', r.id)
     where game = 'dividend' and detail->>'cid' = r.cid;
    update public.app_settings set value = nc where key = 'exchange_cid' and value = r.cid;
    update public.companies set cid = nc where id = r.id;
  end loop;
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
            'tax_state','tax_file','tax_pay','_new_acct','_cfull','_cid_norm','_new_ccode','_xfer_fee','_xfer_check','transfer_preview','transfer_send','work_state','work_start','work_submit','info_state',
            '_find_id','_corp_move','_credit','_is_admin','_my_corp','_bank_accrue','_bank_accrue_all','_corp_card',
            'corp_search','corp_pins','corp_pin','corp_page','corp_buy','my_orders','bank_open','bank_deposit','bank_withdraw',
            'my_banks','corp_apply','my_corps','corp_update','corp_item_save','corp_order_done','corp_send','corp_withdraw',
            'corp_fund','admin_state','admin_corp_decide','corp_job_save','job_list','job_apply','corp_apply_answer',
            'corp_member_set','corp_pay','my_jobs','job_quit',
            '_inv_json','invoice_list','invoice_create','invoice_pay','invoice_close',
            '_corp_holders','_add_shares','corp_shares_change','share_give','my_stocks','corp_dividend','corp_owner_set',
            '_is_friend','friend_list','friend_request','friend_answer','friend_remove','tl_list','tl_post','tl_delete',
            '_fx_market','market_info','fx_state','fx_order','fx_cancel','fx_request','fx_request_cancel','admin_fx_decide',
            '_fx_fee_pct','admin_fx_fee','corp_ca_withdraw','_fx_exch_json','_fx_exchanges','_fx_pick','_fx_cancel_order','exch_settings','_role','_is_staff','_badge','_mail_seen','_cstat','_corp_close',
            'corp_suspend','corp_close','admin_corp_action','_offer_json','share_offer','share_offer_answer','share_offer_cancel',
            '_case_def_owner','_case_json','court_list','court_file','court_defend','court_withdraw','_court_collect_user',
            '_court_collect_comp','admin_court_decide',
            '_pack_json','_loan_accrue','_loan_owed','_loan_json','_loan_start','loan_apply','loan_cancel','loan_repay','_loan_collect',
            'my_loans','bank_acct_answer','bank_settings','loan_pack_save','loan_answer',
            '_rv_flips','_rv_legal','_rv_apply','_game_init','_game_legal','_game_apply','_game_name','_room_finish','_room_tick','_room_json',
            'room_list','room_create','room_join','room_leave','room_state','room_move','room_resign','room_bet','room_chat','room_draw',
            '_ch_at','_ch_attacked','_ch_make','_ch_legal','_ch_init','_ch_apply','_sg_promo','_sg_base','_sg_steps','_sg_slides',
            '_sg_attacked','_sg_make','_sg_legal','_sg_init','_sg_apply',
            '_pub_mine','_pub_can_read','_pub_json','pub_list','news_list','pub_page','pub_read','pub_buy','pub_save','pub_item_save',
            'pub_item_delete','my_pubs','admin_pub_hide',
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
