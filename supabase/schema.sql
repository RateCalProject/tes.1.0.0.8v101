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
-- ハプニング（5レースに1回くらい）
--   deokure 出遅れ（inc_val＝ゲートを出るのが遅れた秒）／rakuba 落馬・競走中止（inc_val＝止まった場所 0〜1）
--   jogai 競走除外（scratch_at に発表。その馬をふくむ馬券は返す）／kouchaku 降着（inc_val＝入線した順位。審議のあと下がる）
alter table public.keiba_entries add column if not exists incident text;
alter table public.keiba_entries add column if not exists inc_val numeric;
alter table public.keiba_entries add column if not exists scratch_at timestamptz;
alter table public.keiba_entries add column if not exists line_pos int;          -- 入線した順位（降着の前）
alter table public.keiba_entries add column if not exists line_margin text;      -- 入線したときの着差（降着のあるレースだけ）
create index if not exists keiba_entries_scr_idx on public.keiba_entries(scratch_at) where incident = 'jogai' and odds_win is not null;
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
alter table public.keiba_tickets add column if not exists refund boolean not null default false;   -- 競走除外で返した馬券
create index if not exists keiba_tickets_user_idx on public.keiba_tickets(user_id, race_id desc);

-- =====================================================================
-- 馬主（競走馬のせり）
--   毎週土曜21:00から24時間、2歳馬のせり（8頭）。いちばん高い値をつけた人が馬主（つけた値はあずかり、ほかの人が上回ったら返す）
--   売れ残りは定価で、次のせりまで買える。そのあとは、ふつうの馬としてデビューする
--   馬主は：名前をつける（デビュー前に1回）・勝負服（色と模様）・出るレースを登録（あしたの番組から。登録しなければ自動で出る）
--           ・引退・ほかの人に売る（売り値の5%が手数料）
--   5着までに入ると賞金（1着は 新馬・未勝利 550 X 〜 G1 15,000 X。2〜5着は 40・25・15・10%）。毎日6時に預託料（1頭20 X。払えないと手放す）
--   持てるのは10頭まで（引退した馬はのぞく。せりで値をつけている馬もふくむ）
--   ※ t46 から：毎週のせりはやめて、新東京競馬競市のせり（運営のイベント）に。預託料はエサ代に。持てる数は無制限（下の「馬の育成」）
-- =====================================================================
alter table public.keiba_horses add column if not exists owner uuid references public.profiles(id) on delete set null;
alter table public.keiba_horses add column if not exists owned_at timestamptz;
alter table public.keiba_horses add column if not exists barn boolean not null default false;   -- せり・定価で売り出し中（レースには出ない）
alter table public.keiba_horses add column if not exists named boolean not null default false;  -- 馬主が名前をつけた
alter table public.keiba_horses add column if not exists earned bigint not null default 0;      -- 馬主が受け取った賞金（X）
create index if not exists keiba_horses_owner_idx on public.keiba_horses(owner) where owner is not null;

-- 馬主（勝負服）
create table if not exists public.kb_owners (
  user_id  uuid primary key references public.profiles(id) on delete cascade,
  silk1    text not null,
  silk2    text not null,
  silk_pat int not null,
  since    timestamptz not null default now()
);
-- 売り出し：せり（auction）・定価（fixed：せりの売れ残り）・馬主が売りに出した馬（resale）
create table if not exists public.kb_sales (
  id          bigserial primary key,
  horse_id    int not null references public.keiba_horses(id) on delete cascade,
  kind        text not null check (kind in ('auction', 'fixed', 'resale')),
  seller      uuid references public.profiles(id) on delete set null,
  week        date,                                   -- せりの日（土曜）
  opens_at    timestamptz not null,
  ends_at     timestamptz not null,
  start_price bigint not null,
  price       bigint,                                 -- せり：いまの値（top があずけている額）／定価・resale：売り値
  top         uuid references public.profiles(id) on delete set null,
  nbids       int not null default 0,
  status      text not null default 'open' check (status in ('open', 'sold', 'unsold', 'cancel', 'expired')),
  buyer       uuid references public.profiles(id) on delete set null,
  sold_price  bigint,
  sold_at     timestamptz,
  info        jsonb not null default '{}'             -- 下見の見立て（評価・距離・芝ダート）
);
create index if not exists kb_sales_open_idx on public.kb_sales(status, ends_at);
create index if not exists kb_sales_horse_idx on public.kb_sales(horse_id, id desc);
create table if not exists public.kb_bids (
  id      bigserial primary key,
  sale_id bigint not null references public.kb_sales(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount  bigint not null,
  at      timestamptz not null default now()
);
create index if not exists kb_bids_sale_idx on public.kb_bids(sale_id, id desc);
-- あしたの番組（芝ダート・距離を前の日に決めておく。出走登録のため）
create table if not exists public.kb_program (
  day      date not null,
  no       int not null,
  post     timestamptz not null,
  venue    int not null,
  rnum     int not null,
  name     text not null,
  grade    text,
  cls      int,
  cond     text not null,
  surface  text not null,
  dist     int not null,
  tier     text not null default 'normal',
  handicap boolean not null default false,
  nmin     int not null,
  nmax     int not null,
  primary key (day, no)
);
-- 出走登録（1頭につき1つ。あしたのレース）
create table if not exists public.kb_regs (
  horse_id int primary key references public.keiba_horses(id) on delete cascade,
  day      date not null,
  no       int not null,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  at       timestamptz not null default now()
);
create index if not exists kb_regs_day_idx on public.kb_regs(day, no);
-- 預託料をとった日（1日1回）
create table if not exists public.kb_upkeep (
  day date primary key,
  at  timestamptz not null default now()
);
alter table public.kb_owners  enable row level security;
alter table public.kb_sales   enable row level security;
alter table public.kb_bids    enable row level security;
alter table public.kb_program enable row level security;
alter table public.kb_regs    enable row level security;
alter table public.kb_upkeep  enable row level security;
revoke all on public.kb_owners, public.kb_sales, public.kb_bids, public.kb_program, public.kb_regs, public.kb_upkeep from anon, authenticated;

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
alter table public.profiles add column if not exists last_seen_at timestamptz;   -- 最後にサイトを開いた時刻（管理の「登録者」）
-- 「登録から7日」の制限がなくなる時刻（null なら 登録＋7日）。2026年10月17日に登録していた人は、その時点で制限をなくした（1回だけ）
alter table public.profiles add column if not exists ok7_at timestamptz;
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'ok7_migrated') then
    update public.profiles set ok7_at = now() where created_at > now() - interval '7 days' and ok7_at is null;
    insert into public.app_settings values ('ok7_migrated', now()::text);
  end if;
end $$;
-- 新しく登録した人は、すぐ全部使える（ok7_at を登録の時刻に）。app_settings の wait7 が 1 なら、今までどおり7日待つ
create or replace function public._ok7_ins() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.ok7_at is null and coalesce((select value from app_settings where key = 'wait7'), '0') <> '1' then
    new.ok7_at := least(coalesce(new.created_at, now()), _now());
  end if;
  return new;
end $$;
drop trigger if exists profiles_ok7 on public.profiles;
create trigger profiles_ok7 before insert on public.profiles for each row execute function public._ok7_ins();
do $$
begin
  if coalesce((select value from public.app_settings where key = 'wait7'), '0') <> '1' then
    update public.profiles set ok7_at = least(created_at, now()) where ok7_at is null or ok7_at > now();
  end if;
end $$;

create or replace function public._ok7(u uuid) returns timestamptz
language sql stable set search_path = public as $$
  select coalesce(ok7_at, created_at + interval '7 days') from profiles where id = u
$$;
-- AIのアカウント（AI会社・AI投資家。ログインできず、IDもない。くわしくは下の「AI会社」）：null なら人
alter table public.profiles add column if not exists ai text;
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
-- AI会社（自動で動く。くわしくは下の「AI会社」）と、AIの社員（名前と役職のある登場人物）
alter table public.companies add column if not exists ai boolean not null default false;
-- 公開価格（上場のとき管理者が決める1株の値段。上場した日の基準値段。取引がまだなければ株価のかわり）
alter table public.companies add column if not exists ipo_price bigint;
-- 株価の起点（上場・株価の決めなおしの時刻）。これより前の取引は、いまの株価・値幅に使わない（null なら上場の時刻）
alter table public.companies add column if not exists price_from timestamptz;
-- 会社が株を持つときの口座（ai = 'corp' のアカウント。はじめて株を受け取るときに作る）。corp_holders ではこの口座が株主になる
alter table public.companies add column if not exists holder uuid references public.profiles(id) on delete set null;
create unique index if not exists companies_holder_idx on public.companies(holder) where holder is not null;
create table if not exists public.ai_staff (
  id         bigserial primary key,
  company_id int not null references public.companies(id) on delete cascade,
  name       text not null,
  title      text not null,
  role       text not null default 'staff',   -- ceo / reporter / trader / analyst / staff
  desk       text not null default '',        -- 部署
  joined     date not null,
  left_on    date
);
alter table public.ai_staff enable row level security;
revoke all on public.ai_staff from anon, authenticated;
-- 会社のID：「会社番号3けた-代表（社長）のID5けた」（例 101-76705）。取引は最初の3けただけでもできる
create or replace function public._cfull(c companies) returns text
language plpgsql stable set search_path = public as $$
begin
  if c.ai then return c.cid; end if;     -- AI会社は会社番号だけ
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
-- ゲスト（メールの確認なしで、メールアドレス＋数字4けたのパスワードで始めた人）。本登録（メールの確認）をすると、ここから消える
--   くわしくは下の「ゲスト」
create table if not exists public.guests (
  id         uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  ip         text                                      -- 作りすぎを止めるため
);
create index if not exists guests_created_idx on public.guests(created_at);
alter table public.guests add column if not exists ext_until timestamptz;   -- 延長した期限（確定申告をしたゲスト。延長すると、5日間来なくても期限までは消えない）
alter table public.guests add column if not exists ext_month int;           -- 延長に使った申告の月（申告した月ごとに1回）
-- ゲストを作った記録（回線ごとの数の制限に使う。3日で消す）
create table if not exists public.guest_signups (
  id bigserial primary key,
  ip text,
  at timestamptz not null default now()
);
create index if not exists guest_signups_idx on public.guest_signups(ip, at);
-- 所持金の上限をこえて受け取れなかった分・消えたゲストの所持金（10分ごとに運営へ）
create table if not exists public.guest_overflow (
  id         bigserial primary key,
  user_id    uuid,
  amount     bigint not null check (amount > 0),
  kind       text not null,                            -- cap（上限をこえた分） / left（消えたゲストの残り）
  created_at timestamptz not null default now()
);
alter table public.guests         enable row level security;
alter table public.guest_signups  enable row level security;
alter table public.guest_overflow enable row level security;
revoke all on public.guests, public.guest_signups, public.guest_overflow from anon, authenticated;

-- ゲストかどうか（本登録すると false）
create or replace function public._is_guest(u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from guests where id = u) or coalesce((select is_anonymous from auth.users where id = u), false)
$$;
-- ゲストが最後に来た時刻（サイトを開いた・遊んだ。はじめた時刻より前にはしない）
create or replace function public._guest_last(u uuid) returns timestamptz
language plpgsql stable set search_path = public as $$
begin
  return greatest((select created_at from guests where id = u),
                  (select last_seen_at from profiles where id = u),
                  (select created_at from tx_log where user_id = u order by id desc limit 1));
end $$;
-- ゲストが消える時刻：はじめてから31日・5日間来ないとき の早いほう（確定申告をして延長したゲストは、のばした期限）
create or replace function public._guest_until(u uuid) returns timestamptz
language plpgsql stable set search_path = public as $$
begin
  -- 延長した人（確定申告をしたゲスト）は、5日間来なくても、のばした期限までは消えない
  return (select case when g.ext_until is not null then g.ext_until
                      else least(g.created_at + interval '31 days', _guest_last(u) + interval '5 days') end
            from guests g where g.id = u);
end $$;
-- ゲストがこの5日間に送金した額（手数料はのぞく）
create or replace function public._guest_sent5(u uuid) returns bigint
language plpgsql stable set search_path = public as $$
begin
  return coalesce((select sum(coalesce((detail->>'amount')::bigint, bet)) from tx_log
                    where user_id = u and game = 'send' and created_at > _now() - interval '5 days'), 0)::bigint;
end $$;

-- いまの人（ゲストもOK）：遊び・見るだけの関数で使う
create or replace function public._me_g() returns uuid
language plpgsql stable set search_path = public as $$
declare u uuid := auth.uid(); bu timestamptz;
begin
  if u is null then raise exception 'ログインしてください'; end if;
  select banned_until into bu from profiles where id = u;
  if not found and not exists (select 1 from auth.users where id = u) then
    raise exception 'このアカウントはもうありません（ゲストの期限が切れて消えました）';
  end if;
  if bu is not null and bu > _now() then
    raise exception '利用停止中です（%まで）。役所の判決によるものです', to_char(bu at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI');
  end if;
  return u;
end $$;

-- いまの人（ゲストはことわる）：送金・株・会社・請求・訴え・投稿など、ほかの人とお金や文がやりとりされるもの
create or replace function public._me() returns uuid
language plpgsql stable set search_path = public as $$
declare u uuid := _me_g();
begin
  if _is_guest(u) then raise exception 'ゲストではできません。本登録（メールの確認）をすると使えます（設定 → プロフィール）'; end if;
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
  if amt > 100 and _is_guest(u) then raise exception 'ゲストの賭け金は1回100 Xまでです（本登録すると上限はなくなります）'; end if;
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
declare b bigint; a text;
begin
  select balance, ai into b, a from profiles where id = u;
  if a is not null then return; end if;      -- AIのアカウントは記録しない
  insert into tx_log(user_id, game, bet, payout, balance_after, detail)
  values (u, g, bet, pay, b, d);
  if g in ('slot','roulette','hilo','blackjack','race','lottery','auction','boat','keirin','fishing','owner') then
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
alter table public.profiles add column if not exists prefs jsonb not null default '{}'::jsonb;   -- ショートカット・テーマ・色覚サポート・言語

create or replace function public.ensure_profile() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); up boolean := false; gtb jsonb;
begin
  insert into profiles(id, nickname, balance)
  values (u, case when _is_guest(u) then 'ゲスト' else 'プレイヤー' end || lpad(_rint(10000)::text, 4, '0'), 1000)
  on conflict (id) do nothing;
  if found then perform _log(u, 'start', 0, 1000, '{"note":"はじめての配布"}'); end if;
  update profiles set account_no = _new_acct() where id = u and account_no is null;
  update profiles set last_seen_at = _now() where id = u;
  perform _mail_seen(u);
  up := _guest_verify(u);     -- ゲストがメールのリンクで入った（メールを確認できた）ら本登録
  -- 締めの日を過ぎていたら、税の締め（調査・差し押さえ・給付金）をここで行う
  -- 万一失敗してもログインは止めない
  begin
    perform _tax_tick();
  exception when others then
    raise warning 'tax tick failed: %', sqlerrm;
  end;
  begin
    gtb := _gt_brief(u);
  exception when others then
    raise warning 'game tasks failed: %', sqlerrm; gtb := null;
  end;
  return (select jsonb_build_object('nickname', nickname, 'balance', balance, 'tax', _tax_badge(u),
            'account_no', account_no, 'is_admin', _is_admin(u), 'role', _role(u), 'event', _is_event(u), 'badge', _badge(u), 'prefs', prefs, 'guest', _is_guest(u),
            'guest_info', _guest_json(u), 'upgraded', up, 'beta', _beta_list(u), 'gt', gtb)
            from profiles where id = u);
end $$;

-- 設定を保存（わたしたものだけ上書き）
create or replace function public.prefs_save(p_prefs jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); p jsonb := coalesce(p_prefs, '{}'::jsonb); cur jsonb; x jsonb;
begin
  if jsonb_typeof(p) <> 'object' then raise exception '設定が正しくありません'; end if;
  select prefs into cur from profiles where id = u;
  cur := coalesce(cur, '{}'::jsonb);
  if p ? 'shortcuts' then
    if jsonb_typeof(p->'shortcuts') <> 'array' or jsonb_array_length(p->'shortcuts') > 16 then raise exception 'ショートカットは16個までです'; end if;
    for x in select * from jsonb_array_elements(p->'shortcuts') loop
      if jsonb_typeof(x) <> 'string' or (x #>> '{}') !~ '^[A-Za-z0-9_]{1,30}(:[A-Za-z0-9_]{1,30})?$' then raise exception 'ショートカットが正しくありません'; end if;
    end loop;
    cur := cur || jsonb_build_object('shortcuts', p->'shortcuts');
  end if;
  if p ? 'theme' then
    if coalesce(p->>'theme', '') not in ('std', 'net2000', 'famicom', 'wa', 'night', 'neon', 'pastel', 'chalk', 'casino', 'win95', 'paper', 'citypop') then
      raise exception 'テーマが正しくありません';
    end if;
    cur := cur || jsonb_build_object('theme', p->>'theme');
  end if;
  if p ? 'cvd' then
    if coalesce(p->>'cvd', '') not in ('off', 'mark', 'safe') then raise exception '色覚サポートの設定が正しくありません'; end if;
    cur := cur || jsonb_build_object('cvd', p->>'cvd');
  end if;
  if p ? 'lang' then
    if coalesce(p->>'lang', '') not in ('ja', 'en', 'zh-TW', 'zh-CN', 'ko', 'ko-Hani') then raise exception '言語が正しくありません'; end if;
    cur := cur || jsonb_build_object('lang', p->>'lang');
  end if;
  update profiles set prefs = cur where id = u;
  return cur;
end $$;

drop function if exists public.my_profile();
create or replace function public.my_profile() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return (select jsonb_build_object('nickname', nickname, 'balance', balance, 'account_no', account_no,
            'send_ok', _now() >= coalesce(ok7_at, created_at + interval '7 days'), 'send_from', _dlabel(coalesce(ok7_at, created_at + interval '7 days')),
            'is_admin', _is_admin(id), 'role', _role(id), 'badge', _badge(id),
            'check', jsonb_build_object('days', _now() >= coalesce(ok7_at, created_at + interval '7 days'), 'days_from', _dlabel(coalesce(ok7_at, created_at + interval '7 days')),
                       'debt', _debt(id), 'mail', mail_verified_at is not null and mail_verified_at >= _now() - interval '183 days',
                       'mail_at', case when mail_verified_at is null then null else _dlabel(mail_verified_at) end,
                       'mail_until', case when mail_verified_at is null then null else _dlabel(mail_verified_at + interval '183 days') end),
            'guest', _guest_json(id), 'gt', _gt_brief(id))
            from profiles where id = _me_g());
end $$;

create or replace function public.set_nickname(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name, ''));
begin
  if char_length(n) < 1 or char_length(n) > 12 then raise exception 'ニックネームは1〜12文字です'; end if;
  update profiles set nickname = n where id = _me_g();
  return my_profile();
end $$;

-- 所持金は非公開なので、お金持ちランキングは出さない（昔の画面から呼ばれても空を返す）
create or replace function public.leaderboard() returns jsonb
language sql security definer set search_path = public as $$ select '[]'::jsonb $$;

create or replace function public.my_history() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('game', game, 'bet', bet, 'payout', payout,
           'balance', balance_after, 'at', created_at) order by id desc), '[]'::jsonb)
  from (select * from tx_log where user_id = _me_g() order by id desc limit 30) t
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
declare u uuid := _me_g(); a int; b int; c int; m int := 0; pay bigint;
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
  u uuid := _me_g(); n int; total bigint := 0; pay bigint := 0; e jsonb;
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
    return jsonb_build_object('active', false, 'balance', _bal(_me_g())) || coalesce(extra, '{}'::jsonb);
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
  select * into g from hilo_games where user_id = _me_g();
  return _hilo_json(g, null);
end $$;

create or replace function public.hilo_start(p_bet bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); g hilo_games; c int := _rint(52);
begin
  if exists (select 1 from hilo_games where user_id = u) then raise exception 'ゲームの途中です'; end if;
  perform _take(u, p_bet);
  insert into hilo_games(user_id, bet, card, cards) values (u, p_bet, c, array[c]) returning * into g;
  return _hilo_json(g, null);
end $$;

create or replace function public.hilo_guess(p_dir text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); g hilo_games; c int; r int; nr int; p numeric; ok boolean; pay bigint;
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
declare u uuid := _me_g(); g hilo_games; pay bigint;
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
  select * into g from bj_games where user_id = _me_g();
  if not found then return jsonb_build_object('active', false, 'balance', _bal(_me_g())); end if;
  return _bj_json(g, false, null, null);
end $$;

create or replace function public.bj_start(p_bet bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); g bj_games; s int[]; pbj boolean; dbj boolean; pay bigint; res text;
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
declare u uuid := _me_g(); g bj_games;
begin
  select * into g from bj_games where user_id = u for update;
  if not found then raise exception 'ゲームが始まっていません'; end if;
  update bj_games set player = player || shoe[pos], pos = pos + 1 where user_id = u returning * into g;
  if _bj_total(g.player) >= 21 then return _bj_finish(g, true); end if;
  return _bj_json(g, false, null, null);
end $$;

create or replace function public.bj_stand() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); g bj_games;
begin
  select * into g from bj_games where user_id = u for update;
  if not found then raise exception 'ゲームが始まっていません'; end if;
  return _bj_finish(g, true);
end $$;

create or replace function public.bj_double() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); g bj_games;
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
   where user_id = u and game in ('slot','roulette','hilo','blackjack','race','work','interest','salary','dividend','liquidation','game_bet','game_stake','pub_sale','review','auction','boat','keirin','fishing','owner','task')
     and created_at >= _month_start(m) and created_at < _month_start(_next_month(m))
$$;

create or replace function public._notice(u uuid, t text) returns void
language sql set search_path = public as $$
  insert into notices(user_id, body) select u, t where not exists (select 1 from profiles where id = u and ai is not null) $$;

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
-- イベント製作者（app_settings 'eventmakers'：ユーザーのID。カンマ区切り）。管理者もイベントをつくれる
create or replace function public._is_event(u uuid) returns boolean
language plpgsql stable set search_path = public as $$
begin
  if u is null then return false; end if;
  if exists (select 1 from app_settings where key = 'admins' and u::text = any(string_to_array(value, ','))) then return true; end if;
  return exists (select 1 from app_settings s join profiles p on p.id = u
                  where s.key = 'eventmakers' and p.account_no = any(string_to_array(replace(s.value, ' ', ''), ',')));
end $$;

-- 名前の横のしるし：role（管理者タグ）と ok（オレンジのチェック）
--   チェック：税金の滞納がない（前に滞納していても、いま払い終わっていればOK）・登録から7日・半年以内にメールで認証
create or replace function public._badge(u uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where id = u;
  if not found then return null; end if;
  return jsonb_build_object('role', _role(u), 'ev', _role(u) is null and _is_event(u),
    'ok', _debt(u) = 0 and _now() >= coalesce(p.ok7_at, p.created_at + interval '7 days')
          and p.mail_verified_at is not null and p.mail_verified_at >= _now() - interval '183 days')
         || coalesce(_gt_badge(u), '{}'::jsonb);   -- 今月の称号・カジノランク
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
language plpgsql stable set search_path = public as $$
begin
  return coalesce((select balance from profiles where id = u), 0)
       + coalesce((select sum(locked) from stock_orders where user_id = u and side = 'buy' and status = 'open'), 0)
       + coalesce((select sum(remain) from fx_orders where user_id = u and side = 'sell' and status = 'open'), 0)
       + coalesce((select bet from hilo_games where user_id = u), 0)
       + coalesce((select bet from bj_games where user_id = u), 0)
       + coalesce((select sum(amount) from keiba_tickets where user_id = u and payout is null), 0)
       + coalesce((select sum(balance) from bank_accounts where user_id = u), 0)
       + coalesce((select sum(balance) from companies where owner = u and status in ('active', 'suspended')), 0);
end $$;

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

  -- ゲストは、その月を申告したときだけ（申告しなければ対象外のまま）
  for p in select pr.id from profiles pr where pr.created_at < mend and pr.ai is null
              and (not _is_guest(pr.id) or exists (select 1 from tax_returns t0 where t0.user_id = pr.id and t0.month = m and t0.declared is not null))
            order by pr.created_at loop
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
    perform _unlock_orders(r.user_id, '差し押さえ');
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
    perform _unlock_orders(r.user_id, '没収');
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
  for r in select * from tax_returns where month = m and declared is not null and ontime and not evasion and not _is_guest(user_id) loop   -- ゲストは給付金なし
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
  select _month_of(min(created_at)) into m from profiles where ai is null;
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
  u uuid := _me_g(); nowt timestamptz; cm int; fm int; d int; created timestamptz; r tax_returns;
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
    from (select * from tax_returns where month = topm and tax_paid > 0 and not _is_guest(user_id) order by tax_paid desc limit 10) t
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
                                   'wage', coalesce(tr.wage_total, 0), 'fee', coalesce(tr.fee_total, 0), 'review', coalesce(tr.review_total, 0), 'task', coalesce(tr.task_total, 0),
                                   'consumption', coalesce(tr.consumption_total, 0)),
    'top', top, 'top_month', topm,
    'balance', _bal(u));
end $$;

-- 申告する（期限内なら何度でも出し直せる）
create or replace function public.tax_file(p_declared bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); nowt timestamptz; cm int; fm int; r tax_returns; refund bigint;   -- ゲストも申告できる（延長のため）
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
declare u uuid := _me_g(); got bigint;
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
--   深夜競馬：メインのあと 20:42 中京・21:42 京都から7レースずつ（22:30の最終レースは曜日ごとの特別）
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
-- 着差の言い方（馬身から）
create or replace function public._kb_margin(lens numeric) returns text
language sql immutable as $$
  select case when lens < 0.06 then 'ハナ' when lens < 0.15 then 'アタマ' when lens < 0.3 then 'クビ'
              when lens < 0.6 then '1/2' when lens < 0.85 then '3/4' when lens < 1.1 then '1'
              when lens < 1.35 then '1 1/4' when lens < 1.6 then '1 1/2' when lens < 1.85 then '1 3/4'
              when lens < 2.25 then '2' when lens < 2.75 then '2 1/2' when lens < 3.25 then '3'
              when lens < 3.75 then '3 1/2' when lens < 10.5 then round(lens)::int::text else '大差' end
$$;

-- 臨時のレースだけ：単勝・複勝などのオッズを、ふだんの何倍にするか（{"tan": 20, "fuku": 20}）・つくった人
alter table public.keiba_races drop column if exists odds_floor;
alter table public.keiba_races add column if not exists odds_mult jsonb;
alter table public.keiba_races add column if not exists made_by uuid references public.profiles(id) on delete set null;

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
  x0 numeric; lbl text; inc text; iu int; m int; k0 int; vv int; xr numeric; force text; er record; regd int[]; rl text;
begin
  if exists (select 1 from keiba_races where id = rid) then return; end if;
  select * into v from keiba_venues where id = vid;
  rl := to_char(posttime at time zone 'Asia/Tokyo', 'HH24:MI');

  -- 馬主が出走登録した馬（賞金の多い順に定員まで）を先に入れる
  regd := _kb_take_regs(d, _kb_make_race.no, cls, cond, nmax, rl, v.name, rnum, nm);
  if coalesce(array_length(regd, 1), 0) > n then n := least(nmax, array_length(regd, 1)); end if;

  -- 出走する馬をえらぶ（せり・定価で売り出し中の馬と、前後の日に出走登録のある馬はのぞく）
  if cls is not null then
    select array_agg(id) into ids from (
      select hh.id from keiba_horses hh
       where not hh.retired and not hh.barn and hh.class = cls and not (hh.id = any(regd))
         and (hh.last_day is null or hh.last_day < d - 1)
         and not exists (select 1 from kb_regs g where g.horse_id = hh.id and g.day between d - 1 and d + 1)
         and case cond when '2yo_new' then cur - hh.born = 2 and hh.starts = 0
                       when '2yo'     then cur - hh.born = 2 and hh.starts > 0
                       when '3yo'     then cur - hh.born = 3
                       else cur - hh.born >= 3 end
       order by -ln(1 - random()) / exp(_kb_fit(hh, surface, dist) / 3)
       limit greatest(n - coalesce(array_length(regd, 1), 0), 0)) z;
  else
    select array_agg(id) into ids from (
      select hh.id from keiba_horses hh
       where not hh.retired and not hh.barn and not (hh.id = any(regd))
         and (hh.last_day is null or hh.last_day < d - 1)
         and not exists (select 1 from kb_regs g where g.horse_id = hh.id and g.day between d - 1 and d + 1)
         and case cond when '3yo' then cur - hh.born = 3 and hh.class >= 2 else hh.class = 4 and cur - hh.born >= 3 end
       order by hh.ability * _kb_agef(cur - hh.born) + _kb_fit(hh, surface, dist) + hh.prize / 3000.0 + _kb_norm() * 3 desc
       limit greatest(n - coalesce(array_length(regd, 1), 0), 0)) z;
  end if;
  ids := regd || coalesce(ids, '{}'::int[]);
  need := n - coalesce(array_length(ids, 1), 0);
  for i in 1..need loop
    k := _kb_new_horse(coalesce(cls, case when cond = '3yo' then 3 else 4 end),
                       case when cond in ('2yo_new', '2yo') then 2 when cond = '3yo' then 3 else 3 + floor(random() * 4)::int end);
    if cond = '2yo' then update keiba_horses set starts = 1 where id = k; end if;
    ids := coalesce(ids, '{}') || k;
  end loop;
  update keiba_horses set last_day = d where id = any(ids);

  insert into keiba_races(id, day, no, post, venue, rnum, name, grade, cls, cond, surface, dist, going, weather, tier, handicap, odds_mult)
  values (rid, d, no, posttime, vid, rnum, nm, grade, cls, cond, surface, dist, going, weather, tier, handicap,
          nullif(coalesce(current_setting('kb.mult', true), ''), '')::jsonb);

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

  -- ハプニング（5レースに1回くらい）：出遅れ 35%・競走除外 25%・落馬 20%・降着 20%
  --   app_settings の kb_incident で決められる（テスト用。none なら起こさない）
  force := coalesce((select value from app_settings where key = 'kb_incident'), '');
  if force in ('deokure', 'jogai', 'rakuba', 'kouchaku') then inc := force;
  elsif force <> 'none' and random() < 0.2 then
    xr := random();
    inc := case when xr < 0.35 then 'deokure' when xr < 0.6 then 'jogai' when xr < 0.8 then 'rakuba' else 'kouchaku' end;
  end if;
  iu := 1 + floor(random() * n)::int;

  -- 着順（本当の力＋運）。運はガンベル分布なので、勝つ確率は人気（オッズ）と同じ形の式になる
  beta := 0.55 * sqrt(dist / 1000.0);
  for i in 1..n loop
    raw[i] := -(rtrue[i] - 50) * 0.1 * dist / 1000.0 - beta * _kb_gumbel();
  end loop;
  if inc = 'deokure' then raw[iu] := raw[iu] + 0.8 + random() * 1.5; end if;      -- 出遅れた分だけ遅い
  -- ゴールする馬（除外・落馬の馬はのぞく）の着順。inc が NULL（ハプニングなし）でも全頭が入るように coalesce
  select array_agg(g order by raw[g]) into order_ix from generate_series(1, n) g
   where not (coalesce(inc, '') in ('jogai', 'rakuba') and g = iu);
  m := array_length(order_ix, 1);

  -- タイム（表示用。着差は本物らしい大きさにちぢめる）
  spd := (17.9 - 0.00052 * dist) * case when surface = '芝' then 1 else 0.965 end
         * case when surface = '芝' then (case going when '稍重' then 0.99 when '重' then 0.978 when '不良' then 0.965 else 1 end)
                else (case going when '稍重' then 1.004 when '重' then 1.008 when '不良' then 1.004 else 1 end) end;
  t0 := dist / spd;
  tw := t0 + 0.5 * raw[order_ix[1]];
  spl := 2.4 * tw / dist;                      -- 1馬身あたりの秒
  x0 := 1 - 600.0 / dist;
  prev := null;
  for k in 1..m loop
    i := order_ix[k];
    dt := raw[i] - raw[order_ix[1]];
    tms[i] := tw + 0.3 * dt + 0.04 * dt * dt;
    if prev is null then
      lbl := null;
    else
      lens := (tms[i] - prev) / spl;
      lbl := _kb_margin(lens);
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
  update keiba_entries set line_pos = pos where race_id = rid;
  -- ハプニングの記録
  if inc = 'deokure' then
    update keiba_entries set incident = 'deokure', inc_val = round((0.4 + random() * 0.7)::numeric, 2) where race_id = rid and uma = iu;
  elsif inc = 'jogai' then         -- 発走の3〜15分前に発表（それまでは買える。その馬をふくむ馬券は返す）
    update keiba_entries set incident = 'jogai', margin = '除外',
           scratch_at = greatest(posttime - make_interval(secs => 180 + floor(random() * 720)), least(_now(), posttime - interval '90 seconds'))
     where race_id = rid and uma = iu;
  elsif inc = 'rakuba' then        -- 走っていたらのタイムで途中まで走り、そこで止まる
    dt := raw[iu] - raw[order_ix[1]];
    select style into c from keiba_horses where id = perm[iu];
    a := (array[0.045, 0.02, -0.012, -0.035])[c + 1] + 0.012 * p * case when c <= 1 then 1 else -1 end;
    update keiba_entries set incident = 'rakuba', inc_val = round((0.2 + random() * 0.6)::numeric, 3), margin = '中止',
           time_ms = round((tw + 0.3 * dt + 0.04 * dt * dt) * 1000)::int, shape = round(a, 4)
     where race_id = rid and uma = iu;
  elsif inc = 'kouchaku' and m >= 3 then
    -- 1〜3位で入線した馬が、すぐうしろ（0.5秒以内）でゴールした馬の進路をじゃまして、その馬のうしろに下がる
    for er in select k1, k1 + 1 + case when k1 + 2 <= m and tms[order_ix[k1 + 2]] - tms[order_ix[k1]] <= 0.5 and random() < 0.3 then 1 else 0 end v1
                from generate_series(1, least(3, m - 1)) k1
               where tms[order_ix[k1 + 1]] - tms[order_ix[k1]] <= 0.5
               order by random() * (array[2, 3, 2])[k1] desc limit 1 loop
      k0 := er.k1; vv := er.v1;
    end loop;
  end if;
  if k0 is not null then
    update keiba_entries set line_margin = margin,
           pos = case when line_pos = k0 then vv when line_pos > k0 and line_pos <= vv then line_pos - 1 else line_pos end
     where race_id = rid;
    update keiba_entries set incident = 'kouchaku', inc_val = k0, margin = null where race_id = rid and line_pos = k0;
    -- 着差は確定の着順でつけなおす（降着の馬はとばす）
    prev := null;
    for er in select e.uma, e.time_ms, e.incident from keiba_entries e where e.race_id = rid order by e.pos loop
      continue when er.incident = 'kouchaku';
      update keiba_entries set margin = case when prev is null then null else _kb_margin((er.time_ms - prev) / 1000.0 / spl) end
       where race_id = rid and uma = er.uma;
      prev := er.time_ms;
    end loop;
  end if;

  -- 人気（みんなの見立て）からオッズ
  select max(x) into rmax from unnest(rpub) x;
  for i in 1..n loop
    update keiba_entries set w = exp((rpub[i] - rmax) * 0.1 * dist / 1000.0 / beta) where race_id = rid and uma = i;
  end loop;
  update keiba_entries set odds_win = _kb_odds(rid, 'tan', array[uma]), odds_place = _kb_odds(rid, 'fuku', array[uma])
   where race_id = rid;
  update keiba_entries e set ninki = z.rk
    from (select uma, row_number() over (order by odds_win, w desc, uma) rk from keiba_entries where race_id = rid) z
   where e.race_id = rid and e.uma = z.uma;
  update keiba_races
     set pace = case when p > 0.6 then 'ハイ' when p < -0.6 then 'スロー' else '平均' end,
         finish_ms = (select max(time_ms) from keiba_entries where race_id = rid and pos is not null)
   where id = rid;
  -- 馬主に知らせる
  for er in select e.uma, h2.owner, h2.name from keiba_entries e join keiba_horses h2 on h2.id = e.horse_id
             where e.race_id = rid and h2.owner is not null loop
    perform _notice(er.owner, format('【馬主】「%s」が %s %s %sR「%s」に出ます（%s番）。', er.name, rl, v.name, rnum, nm, er.uma));
  end loop;
end $$;

-- 天気と馬場：その日、同じ名前の競馬場のレースがもうあれば、それに合わせる（なければくじで）。w0 をわたすと天気はそれ
create or replace function public._kb_wx(d date, vid int, sf text, w0 text default null) returns text[]
language plpgsql volatile set search_path = public as $$
declare vn text; w text := w0; g text; x numeric;
begin
  select name into vn from keiba_venues where id = vid;
  if w is null then
    select r.weather into w from keiba_races r join keiba_venues v on v.id = r.venue
     where r.day = d and v.name = vn order by (r.venue = vid) desc, r.no limit 1;
  end if;
  if w is null then
    x := random();
    w := case when x < 0.5 then '晴' when x < 0.8 then '曇' when x < 0.9 then '小雨' else '雨' end;
  end if;
  select r.going into g from keiba_races r join keiba_venues v on v.id = r.venue
   where r.day = d and v.name = vn and r.surface = sf and r.weather = w order by (r.venue = vid) desc, r.no limit 1;
  if g is null then
    g := case when sf = '芝' then
           case w when '晴' then case when random() < 0.88 then '良' else '稍重' end
                  when '曇' then case when random() < 0.75 then '良' else '稍重' end
                  when '小雨' then case when random() < 0.6 then '稍重' else '重' end
                  else case when random() < 0.55 then '重' else '不良' end end
         else
           case w when '晴' then case when random() < 0.85 then '良' else '稍重' end
                  when '曇' then case when random() < 0.7 then '良' else '稍重' end
                  when '小雨' then case when random() < 0.5 then '稍重' else '重' end
                  else case when random() < 0.5 then '重' else '不良' end end
         end;
  end if;
  return array[w, g];
end $$;

-- 1日分の番組をつくる
create or replace function public._kb_make_day(d date) returns void
language plpgsql volatile set search_path = public as $$
declare
  dow int := extract(isodow from d)::int;
  wk int := (extract(day from d)::int - 1) / 7;
  s int; k int; vid int; posttime timestamptz; v keiba_venues; sf text; ds int; cls int; cond text; nm text;
  wth text[]; gt text[]; gd text[]; x numeric; nr keiba_names; knd text; found_nr boolean; wx text[]; pg kb_program;
begin
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from keiba_races where day = d and no <= 29) then return; end if;   -- 臨時のレース（60〜）は数えない
  for vid in 1..5 loop
    -- 天気と馬場（その日の臨時のレースがもうあれば、同じ競馬場はそれに合わせる）
    wx := _kb_wx(d, vid, '芝'); wth[vid] := wx[1]; gt[vid] := wx[2];
    gd[vid] := (_kb_wx(d, vid, 'ダ', wth[vid]))[2];
  end loop;
  for s in 0..3 loop
    vid := s + 1;
    select * into v from keiba_venues where id = vid;
    for k in 1..7 loop
      posttime := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int,
                                   16 + s, 30, 0, 'Asia/Tokyo') + (k - 1) * interval '8 minutes';
      select * into pg from kb_program p where p.day = d and p.no = s * 7 + k;   -- 前もって決めた番組（出走登録のため）
      if found then sf := pg.surface; ds := pg.dist;
      else
        sf := case when random() < 0.55 then '芝' else 'ダ' end;
        ds := case when sf = '芝' then v.turf_d[1 + floor(random() * array_length(v.turf_d, 1))::int]
                   else v.dirt_d[1 + floor(random() * array_length(v.dirt_d, 1))::int] end;
      end if;
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
                        case when nr.surface = '芝' then gt[coalesce(nr.venue, 5)] else gd[coalesce(nr.venue, 5)] end, wth[coalesce(nr.venue, 5)],
                        case when nr.grade = 'G1' then 'g1' else 'graded' end, nr.handicap,
                        case nr.grade when 'G1' then 16 when 'G2' then 12 when 'G3' then 12 else 10 end,
                        case nr.grade when 'G1' then 18 when 'G2' then 16 when 'G3' then 16 else 14 end);
end $$;

-- 深夜競馬（メインのあと 20:42〜 中京・21:42〜 京都で7Rずつ、8分おき。22:30の最終レースは曜日ごとの特別）
--   番号は30〜43。天気と馬場は、その日の同じ競馬場のふだんのレースと同じ。番組をつくった時点で締め切りの近いレースはつくらない
create or replace function public._kb_make_night(d date) returns void
language plpgsql volatile set search_path = public as $$
declare
  dow int := extract(isodow from d)::int;
  fin text[] := array['月見草特別', '夜霧特別', '銀河特別', '星明かり特別', '真夜中特別', '夜想曲特別', '月光特別'];
  s int; k int; vid int; v keiba_venues; posttime timestamptz; sf text; ds int; cls int; cond text; nm text;
  wth text; gt text; gd text; x numeric; pg kb_program;
begin
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from keiba_races where day = d and no between 30 and 43) then return; end if;
  for s in 0..1 loop
    vid := case s when 0 then 1 else 2 end;
    select * into v from keiba_venues where id = vid;
    select r.weather into wth from keiba_races r where r.day = d and r.venue = vid and r.no <= 28 order by r.no limit 1;
    select r.going into gt from keiba_races r where r.day = d and r.venue = vid and r.no <= 28 and r.surface = '芝' order by r.no desc limit 1;
    select r.going into gd from keiba_races r where r.day = d and r.venue = vid and r.no <= 28 and r.surface = 'ダ' order by r.no desc limit 1;
    if wth is null then
      x := random();
      wth := case when x < 0.5 then '晴' when x < 0.8 then '曇' when x < 0.9 then '小雨' else '雨' end;
    end if;
    gt := coalesce(gt, case wth when '晴' then '良' when '曇' then '良' when '小雨' then '稍重' else '重' end);
    gd := coalesce(gd, case wth when '晴' then '良' when '曇' then '良' when '小雨' then '稍重' else '重' end);
    for k in 1..7 loop
      posttime := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int,
                                   20 + s, 42, 0, 'Asia/Tokyo') + (k - 1) * interval '8 minutes';
      continue when posttime < _now() + interval '2 minutes';   -- もう締め切ったレースはつくらない
      select * into pg from kb_program p where p.day = d and p.no = 30 + s * 7 + (k - 1);   -- 前もって決めた番組（出走登録のため）
      if found then sf := pg.surface; ds := pg.dist;
      else
        sf := case when random() < 0.55 then '芝' else 'ダ' end;
        ds := case when sf = '芝' then v.turf_d[1 + floor(random() * array_length(v.turf_d, 1))::int]
                   else v.dirt_d[1 + floor(random() * array_length(v.dirt_d, 1))::int] end;
      end if;
      case k
        when 1 then cls := 0; cond := case when s = 0 then '2yo_new' else '2yo' end;
        when 2 then cls := 0; cond := '3yo';
        when 3, 4 then cls := 1; cond := '3up';
        when 5, 6 then cls := 2; cond := '3up';
        else cls := 3; cond := '3up';
      end case;
      nm := case when s = 1 and k = 7 then fin[dow]
                 else case cond when '2yo_new' then '2歳新馬' when '2yo' then '2歳未勝利' when '3yo' then '3歳未勝利'
                                else '3歳以上' || cls || '勝クラス' end end;
      perform _kb_make_race(d, 30 + s * 7 + (k - 1), vid, k, posttime, nm, null, cls, cond, sf, ds,
                            case when sf = '芝' then gt else gd end, wth, 'normal', false, 8, 12);
    end loop;
  end loop;
end $$;

-- 昼競馬（12:30〜13:30・府中で10分おきに7R。番号は44〜50）
--   天気・馬場は、その日の府中（18:30の回）と同じ。最終レースは曜日ごとの特別戦。発走2分前をすぎたレースはつくらない
create or replace function public._kb_make_noon(d date) returns void
language plpgsql volatile set search_path = public as $$
declare
  dow int := extract(isodow from d)::int;
  fin text[] := array['青空特別', '日だまり特別', '若葉特別', 'ひまわり特別', '昼下がり特別', '陽光特別', '白雲特別'];
  k int; vid int := 3; v keiba_venues; posttime timestamptz; sf text; ds int; cls int; cond text; nm text;
  wth text; gt text; gd text; x numeric; pg kb_program;
begin
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from keiba_races where day = d and no between 44 and 59) then return; end if;
  select * into v from keiba_venues where id = vid;
  select r.weather into wth from keiba_races r where r.day = d and r.venue = vid and r.no <= 28 order by r.no limit 1;
  select r.going into gt from keiba_races r where r.day = d and r.venue = vid and r.no <= 28 and r.surface = '芝' order by r.no limit 1;
  select r.going into gd from keiba_races r where r.day = d and r.venue = vid and r.no <= 28 and r.surface = 'ダ' order by r.no limit 1;
  if wth is null then
    x := random();
    wth := case when x < 0.5 then '晴' when x < 0.8 then '曇' when x < 0.9 then '小雨' else '雨' end;
  end if;
  gt := coalesce(gt, case wth when '晴' then '良' when '曇' then '良' when '小雨' then '稍重' else '重' end);
  gd := coalesce(gd, case wth when '晴' then '良' when '曇' then '良' when '小雨' then '稍重' else '重' end);
  for k in 1..7 loop
    posttime := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int,
                                 12, 30, 0, 'Asia/Tokyo') + (k - 1) * interval '10 minutes';
    continue when posttime < _now() + interval '2 minutes';   -- もう締め切ったレースはつくらない
    select * into pg from kb_program p where p.day = d and p.no = 43 + k;   -- 前もって決めた番組（出走登録のため）
    if found then sf := pg.surface; ds := pg.dist;
    else
      sf := case when random() < 0.55 then '芝' else 'ダ' end;
      ds := case when sf = '芝' then v.turf_d[1 + floor(random() * array_length(v.turf_d, 1))::int]
                 else v.dirt_d[1 + floor(random() * array_length(v.dirt_d, 1))::int] end;
    end if;
    case k
      when 1 then cls := 0; cond := '2yo_new';
      when 2 then cls := 0; cond := '3yo';
      when 3, 4 then cls := 1; cond := '3up';
      when 5, 6 then cls := 2; cond := '3up';
      else cls := 3; cond := '3up';
    end case;
    nm := case when k = 7 then fin[dow]
               else case cond when '2yo_new' then '2歳新馬' when '3yo' then '3歳未勝利' else '3歳以上' || cls || '勝クラス' end end;
    perform _kb_make_race(d, 43 + k, vid, k, posttime, nm, null, cls, cond, sf, ds,
                          case when sf = '芝' then gt else gd end, wth, 'normal', false, 8, 12);
  end loop;
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
  select array_agg(case when e.scratch_at is not null and e.scratch_at <= _now() then 0 else e.w end order by e.uma),
         array_agg(e.waku order by e.uma) into w, wk from keiba_entries e where e.race_id = rid;
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
declare p numeric; tr text; mu jsonb; o numeric;
begin
  select tier, odds_mult into tr, mu from keiba_races where id = rid;
  p := _kb_prob(rid, kind, sel);
  if p <= 0 then return 99999.9; end if;
  o := round(least(99999.9, greatest(1.0, floor(_kb_rate(tr, kind) / p * 10) / 10)), 1);
  if mu ? kind then o := least(99999.9, round(o * (mu->>kind)::numeric, 1)); end if;     -- 臨時のレース：ふだんのオッズの何倍
  return o;
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
    if exists (select 1 from unnest(s) w0 where (select count(*) from keiba_entries e where e.race_id = rid and e.waku = w0
                 and not (e.scratch_at is not null and e.scratch_at <= _now())) < case when s[1] = s[2] then 2 else 1 end) then
      raise exception 'この枠は競走除外で、走る馬が足りません';
    end if;
    return s;
  end if;
  foreach x in array sel loop
    if x < 1 or x > n then raise exception '馬番は1〜%です', n; end if;
    if exists (select 1 from keiba_entries where race_id = rid and uma = x and scratch_at is not null and scratch_at <= _now()) then
      raise exception '%番は競走除外になりました', x;
    end if;
  end loop;
  if (select count(distinct z) from unnest(sel) z) <> need then raise exception '同じ馬は2回えらべません'; end if;
  if kind in ('umaren', 'wide', 'trio') then
    select array_agg(z order by z) into s from unnest(sel) z;
    return s;
  end if;
  return sel;
end $$;

-- 競走除外を発表したら：その馬のオッズと人気を消し、ほかの馬のオッズと人気をつけなおす
create or replace function public._kb_scratch(rid bigint) returns void
language plpgsql volatile set search_path = public as $$
begin
  update keiba_entries set odds_win = null, odds_place = null, ninki = null
   where race_id = rid and incident = 'jogai' and scratch_at <= _now() and odds_win is not null;
  if not found then return; end if;
  update keiba_entries set odds_win = _kb_odds(rid, 'tan', array[uma]), odds_place = _kb_odds(rid, 'fuku', array[uma])
   where race_id = rid and odds_win is not null;
  update keiba_entries e set ninki = z.rk
    from (select uma, row_number() over (order by odds_win, w desc, uma) rk from keiba_entries where race_id = rid and odds_win is not null) z
   where e.race_id = rid and e.uma = z.uma;
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
  sh numeric[] := array[1, 0.4, 0.25, 0.15, 0.1]; scr int[]; rf boolean; oe record; pz bigint; rl2 text;
begin
  select * into r from keiba_races where id = rid for update;
  if not found or r.settled then return; end if;
  perform _kb_scratch(rid);
  select array_agg(uma order by pos) into res from keiba_entries where race_id = rid and pos is not null;
  select coalesce(array_agg(uma), '{}') into scr from keiba_entries where race_id = rid and incident = 'jogai';
  select array_agg(waku order by uma) into wk from keiba_entries where race_id = rid;
  prize1 := case coalesce(r.grade, '')
              when 'G1' then case when r.name like '%ダービー%' or r.name like '%グランプリ%' then 30000 else 15000 end
              when 'G2' then 5800 when 'G3' then 4100 when 'L' then 2400 when 'OP' then 2200
              else (array[550, 800, 1100, 1500])[coalesce(r.cls, 0) + 1] end;
  for e in select * from keiba_entries where race_id = rid and incident is distinct from 'jogai' loop
    update keiba_horses
       set starts = starts + 1,
           wins   = wins + case when e.pos = 1 then 1 else 0 end,
           class  = case when e.pos = 1 then least(class + 1, 4) else class end,
           graded = graded + case when e.pos = 1 and r.grade in ('G1','G2','G3') then 1 else 0 end,
           prize  = prize + case when e.pos <= 5 then floor(prize1 * sh[e.pos]) else 0 end,
           body   = e.body
     where id = e.horse_id;
  end loop;
  -- 馬主に賞金（5着まで。1万円 = 1 X）
  rl2 := (select name from keiba_venues where id = r.venue);
  for oe in select en.pos, en.horse_id, hh.owner, hh.name from keiba_entries en join keiba_horses hh on hh.id = en.horse_id
             where en.race_id = rid and en.pos between 1 and 5 and en.incident is distinct from 'jogai' and hh.owner is not null loop
    pz := floor(prize1 * sh[oe.pos])::bigint;
    continue when pz <= 0;
    perform _give(oe.owner, pz);
    perform _log(oe.owner, 'owner', 0, pz, jsonb_build_object('race', rid, 'horse', oe.horse_id, 'pos', oe.pos, 'title', format('「%s」%s着', oe.name, oe.pos)));
    update keiba_horses set earned = earned + pz where id = oe.horse_id;
    perform _notice(oe.owner, format('【馬主】「%s」が %s %s %s %sR「%s」で %s着に入りました。賞金 %s X を受け取りました。', oe.name,
                    to_char(r.post at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日"'), to_char(r.post at time zone 'Asia/Tokyo', 'HH24:MI'), rl2, r.rnum, r.name, oe.pos, _fmt(pz)));
  end loop;
  for t in select * from keiba_tickets where race_id = rid and payout is null order by id for update loop
    -- 競走除外の馬をふくむ馬券は返す（枠連は、その枠に走る馬がいなくなったときだけ）
    rf := case when t.kind = 'waku' then exists (select 1 from unnest(t.sel) w0
                 where (select count(*) from keiba_entries x where x.race_id = rid and x.waku = w0 and x.incident is distinct from 'jogai')
                       < case when t.sel[1] = t.sel[2] then 2 else 1 end)
               else t.sel && scr end;
    hit := not rf and _kb_hit(t.kind, t.sel, res, wk);
    pay := case when rf then t.amount when hit then floor(t.amount * t.odds) else 0 end;
    update keiba_tickets set payout = pay, refund = rf where id = t.id;
    perform _give(t.user_id, pay);
    perform _log(t.user_id, 'race', t.amount, pay, jsonb_build_object('race', rid, 'kind', t.kind, 'sel', t.sel) || case when rf then '{"refund": true}'::jsonb else '{}'::jsonb end);
  end loop;
  update keiba_races set settled = true where id = rid;
end $$;

-- 月が変わったら：8歳と、4歳になっても勝てなかった馬は引退。2歳の新馬が入ってくる
create or replace function public._kb_month(cur int) returns void
language plpgsql volatile set search_path = public as $$
declare i int; g record;
begin
  for g in select h.name, h.owner, cur - h.born age, h.class from keiba_horses h
            where not h.retired and h.owner is not null and (cur - h.born >= 8 or (h.class = 0 and cur - h.born >= 4)) loop
    perform _notice(g.owner, format('【馬主】「%s」は%s歳になったので引退しました%s。', g.name, g.age,
                                    case when g.class = 0 and g.age < 8 then '（4歳までに勝てなかった馬は引退）' else '' end));
  end loop;
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
  for r in select distinct e.race_id from keiba_entries e where e.incident = 'jogai' and e.odds_win is not null and e.scratch_at <= _now() loop
    perform _kb_scratch(r.race_id);
  end loop;
  for r in select k.id from keiba_races k
            where not k.settled
              and k.post + make_interval(secs => (coalesce(k.finish_ms, 0)
                    + case when exists (select 1 from keiba_entries e where e.race_id = k.id and e.incident = 'kouchaku') then 50000 else 20000 end) / 1000.0) <= _now()
            order by k.id loop
    perform _kb_settle(r.id);
  end loop;
  select value::int into last from app_settings where key = 'keiba_month';
  if last is null then
    insert into app_settings values ('keiba_month', cur::text) on conflict (key) do nothing;
  elsif last < cur then
    perform _kb_month(cur);
  end if;
  -- 今日の番組（ふだん・メイン）、昼競馬、深夜競馬の順に、呼び出しごとに1つずつつくる（1回の待ち時間を短くするため。最終レースの時刻をすぎていたらつくらない）
  if not exists (select 1 from keiba_races where day = today and no <= 29) then perform _kb_make_day(today);
  elsif _now() < make_timestamptz(extract(year from today)::int, extract(month from today)::int, extract(day from today)::int, 13, 30, 0, 'Asia/Tokyo')
        and not exists (select 1 from keiba_races where day = today and no between 44 and 59) then perform _kb_make_noon(today);
  elsif _now() < make_timestamptz(extract(year from today)::int, extract(month from today)::int, extract(day from today)::int, 22, 30, 0, 'Asia/Tokyo')
        and not exists (select 1 from keiba_races where day = today and no between 30 and 43) then perform _kb_make_night(today);
  elsif not exists (select 1 from kb_program p where p.day = today + 1) then perform _kb_prog_day(today + 1);   -- あしたの番組（出走登録のため）
  end if;
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
declare u uuid := _me_g(); today date;
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
        'part', case when r.no = 29 then 'main' when r.no >= 60 then 'extra' when r.no >= 44 then 'noon' when r.no >= 30 then 'night' else 'day' end,
        'sess', case when r.no <= 28 then (r.no - 1) / 7 when r.no = 29 then 4 when r.no >= 60 then 100 + r.no when r.no >= 44 then 7 else 5 + (r.no - 30) / 7 end,
        'n', (select count(*) from keiba_entries e where e.race_id = r.id and not (e.scratch_at is not null and e.scratch_at <= _now())),
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
  u uuid := _me_g(); r keiba_races; v keiba_venues; st text; started boolean; ent jsonb; pays jsonb := '[]'::jsonb;
  mine jsonb; res int[]; wk int[]; n int; s int[]; kou boolean; own_ok boolean := _beta_ok(u, 'owner');
begin
  perform _kb_tick();
  select * into r from keiba_races where id = p_race;
  if not found then raise exception 'レースが見つかりません'; end if;
  select * into v from keiba_venues where id = r.venue;
  st := _kb_status(r);
  started := r.post <= _now();
  kou := exists (select 1 from keiba_entries e where e.race_id = r.id and e.incident = 'kouchaku');

  select jsonb_agg(jsonb_build_object(
      'uma', e.uma, 'waku', e.waku, 'horse_id', h.id, 'name', h.name, 'sex', h.sex, 'age', e.age,
      'kinryo', e.kinryo, 'jockey', j.name, 'body', e.body, 'body_diff', e.body_diff, 'style', h.style,
      'coat', h.coat, 'silk1', h.silk1, 'silk2', h.silk2, 'silk_pat', h.silk_pat,
      'odds_win', e.odds_win, 'odds_place', e.odds_place, 'ninki', e.ninki,
      'scratched', e.scratch_at is not null and e.scratch_at <= _now(),
      'record', format('%s戦%s勝', h.starts, h.wins), 'graded', h.graded,
      'owner', case when own_ok and h.owner is not null then (select p.nickname from profiles p where p.id = h.owner) end,
      'mine', own_ok and h.owner = u,
      'last5', (select coalesce(jsonb_agg(jsonb_build_object('pos', x.pos, 'n', x.n, 'grade', x.grade, 'inc', x.incident,
                         'dist', x.dist, 'surface', x.surface, 'venue', x.venue) order by x.race_id desc), '[]'::jsonb)
                  from (select e2.race_id, e2.pos, e2.incident, r2.grade, r2.dist, r2.surface, v2.name venue,
                               (select count(*) from keiba_entries e3 where e3.race_id = e2.race_id and e3.incident is distinct from 'jogai') n
                          from keiba_entries e2 join keiba_races r2 on r2.id = e2.race_id
                          join keiba_venues v2 on v2.id = r2.venue
                         where e2.horse_id = h.id and e2.race_id < r.id and r2.settled
                         order by e2.race_id desc limit 5) x),
      'run', case when not started then null
                  when e.incident = 'jogai' then jsonb_build_object('scratched', true)
                  else jsonb_build_object('pos', case when r.settled then e.pos else coalesce(e.line_pos, e.pos) end, 'time_ms', e.time_ms,
                         'margin', case when kou and not r.settled then e.line_margin else e.margin end,
                         'last3f', e.last3f, 'shape', e.shape, 'lane', e.lane,
                         'delay', case when e.incident = 'deokure' then e.inc_val end,      -- 出遅れ（秒）
                         'stop', case when e.incident = 'rakuba' then e.inc_val end,        -- 落馬して止まった場所（0〜1）
                         'line', case when r.settled and e.incident = 'kouchaku' then e.line_pos end) end   -- 降着：入線した順位
    ) order by e.uma) into ent
    from keiba_entries e join keiba_horses h on h.id = e.horse_id join keiba_jockeys j on j.id = e.jockey
   where e.race_id = r.id;

  if r.settled then
    select array_agg(uma order by pos) into res from keiba_entries where race_id = r.id and pos is not null;
    select count(*) into n from keiba_entries where race_id = r.id;
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
                                               'payout', t.payout, 'refund', t.refund) order by t.id), '[]'::jsonb) into mine
    from keiba_tickets t where t.race_id = r.id and t.user_id = u;

  return jsonb_build_object(
    'now_ms', _kb_ms(_now()),
    'race', jsonb_build_object(
      'id', r.id, 'no', r.no, 'rnum', r.rnum, 'day', r.day, 'post_ms', _kb_ms(r.post), 'status', st,
      'name', r.name, 'grade', r.grade, 'cls', r.cls, 'cond', r.cond, 'surface', r.surface, 'dist', r.dist,
      'going', r.going, 'weather', r.weather, 'tier', r.tier, 'handicap', r.handicap, 'mult', r.odds_mult,
      'pace', case when started then r.pace end, 'finish_ms', case when started then r.finish_ms end,
      'inquiry', kou and started and _now() >= r.post + make_interval(secs => coalesce(r.finish_ms, 0) / 1000.0),   -- 審議（ゴールのあと）
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
declare u uuid := _me_g(); s int[];
begin
  s := _kb_check_sel(p_race, p_kind, p_sel);
  return jsonb_build_object('sel', s, 'odds', _kb_odds(p_race, p_kind, s));
end $$;

-- 馬券を買う（オッズは買った時点で決まる）
create or replace function public.keiba_bet(p_race bigint, p_kind text, p_sel int[], p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r keiba_races; s int[]; od numeric;
begin
  perform _kb_tick();
  select * into r from keiba_races where id = p_race;
  if not found then raise exception 'レースが見つかりません'; end if;
  if _now() >= r.post - interval '60 seconds' then raise exception 'このレースの発売は締め切りました'; end if;
  if r.made_by = u and not _is_admin(u) then raise exception '自分がつくった臨時のレースの馬券は買えません'; end if;
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
declare u uuid := _me_g(); h keiba_horses;
begin
  select * into h from keiba_horses where id = p_horse;
  if not found then raise exception '馬が見つかりません'; end if;
  return jsonb_build_object(
    'name', h.name, 'sex', h.sex, 'age', _kb_midx(_now()) - h.born, 'coat', h.coat, 'style', h.style,
    'silk1', h.silk1, 'silk2', h.silk2, 'silk_pat', h.silk_pat, 'body', h.body,
    'class', h.class, 'starts', h.starts, 'wins', h.wins, 'prize', h.prize, 'graded', h.graded, 'retired', h.retired,
    'owner', case when h.owner is not null and _beta_ok(u, 'owner') then (select p.nickname from profiles p where p.id = h.owner) end,
    'mine', h.owner = u and _beta_ok(u, 'owner'), 'earned', case when h.owner = u then h.earned end,
    'runs', (select coalesce(jsonb_agg(jsonb_build_object(
                 'day', r.day, 'venue', v.name, 'name', r.name, 'grade', r.grade, 'surface', r.surface, 'dist', r.dist,
                 'going', r.going, 'n', (select count(*) from keiba_entries e3 where e3.race_id = r.id and e3.incident is distinct from 'jogai'),
                 'uma', e.uma, 'ninki', e.ninki, 'pos', e.pos, 'time_ms', e.time_ms, 'margin', e.margin,
                 'inc', e.incident, 'line', case when e.incident = 'kouchaku' then e.line_pos end,
                 'last3f', e.last3f, 'jockey', j.name, 'kinryo', e.kinryo, 'body', e.body, 'body_diff', e.body_diff
               ) order by r.id desc), '[]'::jsonb)
               from keiba_entries e join keiba_races r on r.id = e.race_id join keiba_venues v on v.id = r.venue
               join keiba_jockeys j on j.id = e.jockey
              where e.horse_id = h.id and r.settled));
end $$;

-- ---------------------------------------------------------------------
-- 臨時のレース（管理者がつくる。番号60〜99。きょうかあした）
-- ---------------------------------------------------------------------
create or replace function public.admin_kb_extras() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); today date; adm boolean := _is_admin(u);
begin
  if not _is_event(u) then raise exception '管理者とイベント製作者だけが使えます'; end if;
  today := _kb_jday(_now());
  return jsonb_build_object(
    'now_ms', _kb_ms(_now()), 'today', today, 'admin', adm, 'mult_max', case when adm then 100 else 20 end,
    'venues', (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'turf_d', turf_d, 'dirt_d', dirt_d)
                 order by case id when 3 then 1 when 2 then 2 else 3 end) from keiba_venues where id in (1, 2, 3)),
    'races', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'day', r.day, 'post_ms', _kb_ms(r.post), 'rnum', r.rnum,
                'venue', v.name, 'name', r.name, 'grade', r.grade, 'cls', r.cls, 'surface', r.surface, 'dist', r.dist,
                'weather', r.weather, 'going', r.going, 'status', _kb_status(r), 'mult', r.odds_mult,
                'n', (select count(*) from keiba_entries e where e.race_id = r.id),
                'tickets', (select count(*) from keiba_tickets t where t.race_id = r.id),
                'bet', (select coalesce(sum(t.amount), 0) from keiba_tickets t where t.race_id = r.id),
                'by', (select nickname from profiles where id = r.made_by), 'mine', r.made_by = u, 'can_cancel', adm or r.made_by = u) order by r.post desc), '[]'::jsonb)
              from keiba_races r join keiba_venues v on v.id = r.venue where r.no >= 60 and r.day >= today - 7));
end $$;

drop function if exists public.admin_kb_extra(text, int, text, int, text, int, text, int, text, boolean, int, int, boolean);
drop function if exists public.admin_kb_extra(text, int, text, int, text, int, text, int, text, boolean, int, int, boolean, numeric, boolean);   -- 前の版
create or replace function public.admin_kb_extra(p_name text, p_day int, p_time text, p_venue int, p_surface text, p_dist int,
  p_grade text, p_cls int, p_cond text, p_handicap boolean, p_n int, p_rnum int, p_banner boolean default false,
  p_mult numeric default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _me(); nm text := btrim(coalesce(p_name, '')); gr text := nullif(btrim(coalesce(p_grade, '')), '');
  fl numeric := nullif(nullif(round(p_mult, 1), 0), 1); adm boolean := _is_admin(u);
  cnd text := coalesce(p_cond, '3up'); d date; pt timestamptz; v keiba_venues; no int; rid bigint; wx text[]; cl int; hh int; mi int;
begin
  if not _is_event(u) then raise exception '管理者とイベント製作者だけが使えます'; end if;
  perform _kb_tick();
  if char_length(nm) < 1 or char_length(nm) > 30 then raise exception 'レース名は1〜30文字にしてください'; end if;
  if p_day is null or p_day not in (0, 1) then raise exception '日にちは、きょうかあしたです'; end if;
  if coalesce(p_time, '') !~ '^[0-9]{1,2}:[0-9]{2}$' then raise exception '発走時刻は 17:15 のように書いてください'; end if;
  hh := split_part(p_time, ':', 1)::int; mi := split_part(p_time, ':', 2)::int;
  if hh > 23 or mi > 59 then raise exception '発走時刻が正しくありません'; end if;
  d := _kb_jday(_now()) + p_day;
  pt := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, hh, mi, 0, 'Asia/Tokyo');
  if pt < _now() + interval '5 minutes' then raise exception '発走は、いまから5分よりあとにしてください（馬券を買う時間がいるため）'; end if;
  select * into v from keiba_venues where id = p_venue and id in (1, 2, 3);
  if not found then raise exception '競馬場をえらんでください'; end if;
  if coalesce(p_surface, '') not in ('芝', 'ダ') then raise exception '芝かダートをえらんでください'; end if;
  if p_dist is null or not (p_dist = any(case when p_surface = '芝' then v.turf_d else v.dirt_d end)) then
    raise exception '%の%では、その距離のレースはできません', v.name, case when p_surface = '芝' then '芝' else 'ダート' end;
  end if;
  if gr is not null and gr not in ('G1', 'G2', 'G3', 'L', 'OP') then raise exception 'グレードが正しくありません'; end if;
  if gr is null then
    if p_cls is null or p_cls not between 0 and 3 then raise exception 'クラスをえらんでください'; end if;
    cl := p_cls;
  end if;
  if cnd not in ('3up', '3yo') then raise exception '出走できる馬の条件が正しくありません'; end if;
  if p_n is null or p_n not between 8 and 18 then raise exception '頭数は8〜18頭です'; end if;
  if p_rnum is null or p_rnum not between 1 and 12 then raise exception 'レース番号は1〜12Rです'; end if;
  if fl is not null and (fl < 1.1 or fl > 100) then raise exception 'オッズの倍率は1.1〜100倍にしてください（ふだんのオッズの何倍か）'; end if;
  if fl is not null and fl > 20 and not adm then raise exception 'イベント製作者がつけられるオッズの倍率は20倍までです'; end if;
  perform pg_advisory_xact_lock(4242);
  select coalesce(max(k.no), 59) + 1 into no from keiba_races k where k.day = d and k.no >= 60;
  if no > 99 then raise exception '臨時のレースは1日40レースまでです'; end if;
  rid := to_char(d, 'YYYYMMDD')::bigint * 100 + no;
  wx := _kb_wx(d, p_venue, p_surface);
  perform set_config('kb.mult', case when fl is not null then jsonb_build_object('tan', fl, 'fuku', fl)::text else '' end, true);
  perform _kb_make_race(d, no, p_venue, p_rnum, pt, nm, gr, cl, cnd, p_surface, p_dist, wx[2], wx[1],
                        case when gr = 'G1' then 'g1' when gr is not null then 'graded' else 'normal' end,
                        coalesce(p_handicap, false), p_n, p_n);
  perform set_config('kb.mult', '', true);
  update keiba_races set made_by = u where id = rid;
  if coalesce(p_banner, false) then
    insert into banners(body, kind, link, starts_at, ends_at, by_user, created_at)
    values (format('臨時競馬「%s」%s　%s %s 発走（%s %s%sm）', nm, case when gr is not null then '（' || gr || '）' else '' end,
                   case when p_day = 0 then 'きょう' else 'あした' end, to_char(pt at time zone 'Asia/Tokyo', 'HH24:MI'),
                   v.name, case when p_surface = '芝' then '芝' else 'ダート' end, p_dist)
            || case when fl is not null then format('　単勝・複勝のオッズは、ふだんの%s倍', case when fl = trunc(fl) then trunc(fl)::text else fl::text end) else '' end,
            'event', 'race:' || rid, _now(), pt + interval '5 minutes', u, _now());
  end if;
  return jsonb_build_object('id', rid, 'weather', wx[1], 'going', wx[2], 'n', (select count(*) from keiba_entries where race_id = rid));
end $$;

-- 発走の前なら取り消せる（買われた馬券は全額返す）
create or replace function public.admin_kb_extra_cancel(p_race bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); r keiba_races; t keiba_tickets; n int := 0; tot bigint := 0; hs int[]; x record;
begin
  if not _is_event(u) then raise exception '管理者とイベント製作者だけが使えます'; end if;
  select * into r from keiba_races where id = p_race for update;
  if not found or r.no < 60 then raise exception '臨時のレースが見つかりません'; end if;
  if not _is_admin(u) and r.made_by is distinct from u then raise exception '自分がつくった臨時のレースだけ取り消せます'; end if;
  if r.settled or r.post <= _now() then raise exception '発走したレースは取り消せません'; end if;
  for t in select * from keiba_tickets where race_id = p_race and payout is null order by id for update loop
    perform _give(t.user_id, t.amount);
    perform _log(t.user_id, 'race', t.amount, t.amount, jsonb_build_object('race', p_race, 'kind', t.kind, 'sel', t.sel, 'refund', true, 'cancel', true));
    n := n + 1; tot := tot + t.amount;
  end loop;
  for x in select user_id, count(*) k, sum(amount)::bigint a from keiba_tickets where race_id = p_race group by user_id loop
    perform _notice(x.user_id, format('臨時競馬「%s」は取り消しになりました。馬券%s枚の %s X を返しました', r.name, x.k, _fmt(x.a)));
  end loop;
  select array_agg(horse_id) into hs from keiba_entries where race_id = p_race;
  update banners set ended = true where link = 'race:' || p_race and not ended;
  delete from keiba_races where id = p_race;          -- 出走馬と馬券もいっしょに消える
  update keiba_horses h set last_day = (select max(r2.day) from keiba_entries e join keiba_races r2 on r2.id = e.race_id where e.horse_id = h.id)
   where h.id = any(hs);
  return jsonb_build_object('refunded', n, 'amount', tot);
end $$;

-- ---------------------------------------------------------------------
-- 副管理者・イベント製作者（管理者が決める。ユーザーのIDで）
-- ---------------------------------------------------------------------
create or replace function public._staff_list(k text) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.account_no, 'nickname', p.nickname) order by x.o), '[]'::jsonb)
    from unnest(string_to_array(replace(coalesce((select value from app_settings where key = k), ''), ' ', ''), ',')) with ordinality x(a, o)
    join profiles p on p.account_no = x.a
$$;
create or replace function public.admin_staff() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  if not _is_admin(u) then raise exception '管理者だけが使えます'; end if;
  return jsonb_build_object('sub', _staff_list('subadmins'), 'event', _staff_list('eventmakers'));
end $$;
-- p_kind：sub（副管理者）/ event（イベント製作者）。p_ids：ユーザーのID（カンマ・空白区切り。空なら、だれもいない）
create or replace function public.admin_staff_set(p_kind text, p_ids text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); k text; ids text[]; a text; old text[]; pid uuid; nm text; lbl text;
begin
  if not _is_admin(u) then raise exception '管理者だけが使えます'; end if;
  k := case p_kind when 'sub' then 'subadmins' when 'event' then 'eventmakers' end;
  if k is null then raise exception '役割をえらんでください'; end if;
  lbl := case p_kind when 'sub' then '副管理者' else 'イベント製作者' end;
  select coalesce(array_agg(distinct z) filter (where z <> ''), '{}') into ids
    from unnest(regexp_split_to_array(coalesce(p_ids, ''), '[\s,、，]+')) z;
  if array_length(ids, 1) > 20 then raise exception '%は20人までです', lbl; end if;
  foreach a in array ids loop
    select id, nickname into pid, nm from profiles where account_no = a and ai is null;
    if not found then raise exception 'ID %の人が見つかりません', a; end if;
    if _is_guest(pid) then raise exception '%さんはゲストなので、%にできません', nm, lbl; end if;
    if _is_admin(pid) then raise exception '%さんは管理者です', nm; end if;
  end loop;
  old := string_to_array(replace(coalesce((select value from app_settings where key = k), ''), ' ', ''), ',');
  insert into app_settings(key, value) values (k, array_to_string(ids, ',')) on conflict (key) do update set value = excluded.value;
  -- なった人・はずれた人に知らせる
  for pid in select p.id from profiles p where p.account_no = any(ids) and not (p.account_no = any(coalesce(old, '{}'))) loop
    perform _notice(pid, case p_kind when 'sub' then '【お知らせ】副管理者になりました。設定 → 管理 から、企業や上場の審査・訴えの審理などができます。'
                              else '【お知らせ】イベント製作者になりました。設定 → 管理 から、臨時のレースとお知らせバナーをつくれます。' end);
  end loop;
  for pid in select p.id from profiles p where p.account_no = any(coalesce(old, '{}')) and not (p.account_no = any(ids)) loop
    perform _notice(pid, format('【お知らせ】%sからはずれました。', lbl));
  end loop;
  return admin_staff();
end $$;

-- ---------------------------------------------------------------------
-- お知らせバナー（画面の上に出す。管理者が出す・消す。見る人は×で閉じられる）
-- ---------------------------------------------------------------------
create table if not exists public.banners (
  id         bigserial primary key,
  body       text not null,
  kind       text not null default 'info' check (kind in ('info', 'warn', 'event')),
  link       text,                                  -- race:<レースの番号> か https のURL
  starts_at  timestamptz not null default now(),
  ends_at    timestamptz,                           -- null なら、消すまで出しておく
  ended      boolean not null default false,
  by_user    uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.banners enable row level security;
revoke all on public.banners from anon, authenticated;

create or replace function public.banner_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'body', b.body, 'kind', b.kind, 'link', b.link) order by b.id desc), '[]'::jsonb)
            from (select * from banners where not ended and starts_at <= _now() and (ends_at is null or ends_at > _now())
                   order by id desc limit 5) b);
end $$;

create or replace function public.admin_banners() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); adm boolean := _is_admin(u);
begin
  if not _is_event(u) then raise exception '管理者とイベント製作者だけが使えます'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'body', b.body, 'kind', b.kind, 'link', b.link,
            'at', _dlabel(b.created_at), 'time', to_char(b.created_at at time zone 'Asia/Tokyo', 'HH24:MI'),
            'until', case when b.ends_at is null then null else to_char(b.ends_at at time zone 'Asia/Tokyo', 'FMMM/FMDD HH24:MI') end,
            'live', not b.ended and b.starts_at <= _now() and (b.ends_at is null or b.ends_at > _now()),
            'by', p.nickname, 'mine', b.by_user = u, 'can_end', adm or b.by_user = u) order by b.id desc), '[]'::jsonb)
          from (select * from banners order by id desc limit 20) b left join profiles p on p.id = b.by_user);
end $$;

-- p_hours：0＝消すまで、-1＝きょういっぱい、1〜720＝その時間
create or replace function public.admin_banner_save(p_body text, p_kind text, p_hours int, p_link text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); b text := btrim(coalesce(p_body, '')); lk text := nullif(btrim(coalesce(p_link, '')), ''); en timestamptz; id0 bigint;
begin
  if not _is_event(u) then raise exception '管理者とイベント製作者だけが使えます'; end if;
  if char_length(b) < 1 or char_length(b) > 200 then raise exception 'お知らせは1〜200文字にしてください'; end if;
  if coalesce(p_kind, '') not in ('info', 'warn', 'event') then raise exception '種類が正しくありません'; end if;
  if lk is not null and not (lk ~ '^race:[0-9]+$' or (lk ~* '^https://[^ ]+$' and char_length(lk) <= 300)) then
    raise exception 'リンクは https:// ではじまるURLにしてください';
  end if;
  if p_hours is null or not (p_hours in (0, -1) or p_hours between 1 and 720) then raise exception '出しておく期間が正しくありません'; end if;
  en := case when p_hours = 0 then null
             when p_hours = -1 then (_kb_jday(_now()) + 1)::timestamp at time zone 'Asia/Tokyo'
             else _now() + make_interval(hours => p_hours) end;
  insert into banners(body, kind, link, starts_at, ends_at, by_user, created_at) values (b, p_kind, lk, _now(), en, u, _now()) returning id into id0;
  return jsonb_build_object('id', id0);
end $$;

create or replace function public.admin_banner_end(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); by0 uuid;
begin
  if not _is_event(u) then raise exception '管理者とイベント製作者だけが使えます'; end if;
  select by_user into by0 from banners where id = p_id;
  if not found then raise exception 'お知らせが見つかりません'; end if;
  if not _is_admin(u) and by0 is distinct from u then raise exception '自分が出したお知らせだけ消せます'; end if;
  update banners set ended = true where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 送金（口座番号で相手を指定。手数料1%・最低1 X は国庫へ）
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
  for r in select id from public.profiles where account_no is null and ai is null loop
    update public.profiles set account_no = public._new_acct() where id = r.id;
  end loop;
end $$;

create or replace function public._xfer_fee(amt bigint) returns bigint
language sql immutable as $$ select greatest(1, floor(amt * 0.01))::bigint $$;

-- 消費税：会社の商品・新聞／本・請求の支払いの値段（請求額）の中にふくまれる。税ぬきの2%（値段の102分の2・切り捨て）、1回 1,500 X まで
--   買う人・払う人の払う額は変わらない。売る側（会社・書いた人・請求した人）に入る額から引いて国庫へ
create or replace function public._ctax(p bigint) returns bigint
language sql immutable as $$ select least(floor(greatest(coalesce(p, 0), 0) * 2 / 102.0), 1500)::bigint $$;
alter table public.treasury add column if not exists consumption_total bigint not null default 0;   -- 消費税（累計）
alter table public.corp_orders add column if not exists tax bigint not null default 0;              -- 注文の消費税

-- IDから相手（ユーザーか会社）をさがす
create or replace function public._find_id(p_to text, out rid uuid, out rcomp int, out rname text, out rcreated timestamptz)
language plpgsql stable set search_path = public as $$
declare k text := btrim(coalesce(p_to, ''));
begin
  select id, nickname, created_at into rid, rname, rcreated from profiles where account_no = k;
  if found then return; end if;
  if exists (select 1 from companies where cid = _cid_norm(k) and ai) then raise exception 'AIの会社は、送金・請求などの相手にできません'; end if;
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
    okday := coalesce(me.ok7_at, me.created_at + interval '7 days');
    if _now() < okday then raise exception '登録から7日たつまで送金できません（%から送れます）', _dlabel(okday); end if;
    if _debt(u) > 0 then raise exception '税金の滞納があるので送金できません'; end if;
    perform _guest_send_check(u, p_amount);     -- ゲスト：はじめて7日は送れない・5日間で2,000 Xまで
    have := me.balance;
  else
    select * into c from companies where id = src_comp and owner = u and status = 'active';
    if not found then raise exception 'この会社からは送れません'; end if;
    if t.rcomp = src_comp then raise exception '同じ会社には送れません'; end if;
    have := c.balance;
  end if;
  if t.rid is not null and _now() < _ok7(t.rid) then
    raise exception '相手は登録から7日たっていないので、まだ受け取れません';
  end if;
  if t.rid is not null and _is_guest(t.rid) then raise exception '相手はゲストなので、送金を受け取れません'; end if;
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
  select * into c from _xfer_check(_me_g(), p_to, p_amount, null);
  return jsonb_build_object('nickname', c.rnick, 'company', c.rcomp is not null, 'amount', p_amount, 'fee', c.fee, 'total', p_amount + c.fee);
end $$;

create or replace function public.transfer_send(p_to text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); c record; me profiles;
begin
  select * into c from _xfer_check(u, p_to, p_amount, null);                  -- 相手をさがす
  perform 1 from profiles where id in (u, c.rid) order by id for update;     -- 自分と相手を id の順にロック
  select * into c from _xfer_check(u, p_to, p_amount, null);                  -- ロックしたあとの残高で、もう一度調べる
  select * into me from profiles where id = u;
  update profiles set balance = balance - (p_amount + c.fee) where id = u;
  perform _log(u, 'send', p_amount + c.fee, 0, jsonb_build_object('to', c.rnick, 'id', btrim(p_to), 'amount', p_amount, 'fee', c.fee));
  perform _credit(c.rid, c.rcomp, p_amount, me.nickname || ' さん', me.account_no);
  update treasury set balance = balance + c.fee, fee_total = fee_total + c.fee where id = 1;   -- 国庫は最後
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
declare u uuid := _me_g(); today date := _kb_jday(_now());
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
  u uuid := _me_g(); today date := _kb_jday(_now()); qs jsonb := '[]'; ans jsonb := '[]';
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
declare u uuid := _me_g(); j work_jobs; i int; c int := 0; wage bigint; secs numeric;
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
declare u uuid := _me_g(); tr treasury;
begin
  select * into tr from treasury where id = 1;
  return jsonb_build_object(
    'players', (select count(*) from profiles where ai is null and not _is_guest(id)),
    'companies', (select count(*) from companies where status = 'active'),
    'wage', coalesce(tr.wage_total, 0), 'fee', coalesce(tr.fee_total, 0),
    -- 競馬億万長者：今週（月曜から）の競馬の勝ち（払戻 − 賭け金）の合計
    'week_from', _dlabel((_kb_jday(_now()) - (extract(isodow from _kb_jday(_now()))::int - 1))::timestamp at time zone 'Asia/Tokyo'),
    'jackpots', (select coalesce(jsonb_agg(z order by z.net desc), '[]'::jsonb) from (
        select p.nickname, _badge(p.id) badge, sum(t.payout - t.amount)::bigint net, sum(t.payout)::bigint payout, sum(t.amount)::bigint bet,
               count(*) filter (where t.payout > 0 and not t.refund) hits, max(t.payout)::bigint best
          from keiba_tickets t join profiles p on p.id = t.user_id join keiba_races r on r.id = t.race_id
         where t.payout is not null and r.day >= _kb_jday(_now()) - (extract(isodow from _kb_jday(_now()))::int - 1) and not _is_guest(p.id)
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

-- まだ公開していないゲーム（app_settings 'beta_games'：カンマ区切り。ないときは boat・bike・auction・koikoi・fishing）。それまでは管理者だけ遊べる
--   公開するときは、そのゲームを一覧から消す（例：update app_settings set value = 'fishing' where key = 'beta_games'）
create or replace function public._beta_games() returns text[]
language sql stable set search_path = public as $$
  select array(select x from unnest(string_to_array(replace(coalesce((select value from app_settings where key = 'beta_games'),
                                                                     'boat,bike,auction,koikoi,fishing'), ' ', ''), ',')) x where x <> '')
$$;
create or replace function public._beta_ok(u uuid, g text) returns boolean
language sql stable set search_path = public as $$ select _is_admin(u) or not (g = any(_beta_games())) $$;
-- 画面に出さないゲーム（管理者には何もかくさない）
create or replace function public._beta_list(u uuid) returns jsonb
language sql stable set search_path = public as $$ select case when _is_admin(u) then '[]'::jsonb else to_jsonb(_beta_games()) end $$;

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
-- 認証マーク：サイトの認証を受けた会社に、管理者がつける（1週間〜3ヶ月の期限つき）
alter table public.companies add column if not exists cert_until timestamptz;   -- この時刻まで認証マーク
alter table public.companies add column if not exists cert_note  text;          -- 管理者のメモ（認証の理由など）
create table if not exists public.corp_cert_log (
  id         bigserial primary key,
  company_id int not null references public.companies(id) on delete cascade,
  by_user    uuid references public.profiles(id) on delete set null,
  until      timestamptz,                                  -- null は取り消し
  note       text,
  at         timestamptz not null default now()
);
alter table public.corp_cert_log enable row level security;
revoke all on public.corp_cert_log from anon, authenticated;
-- 業種（日本標準産業分類の中分類）・ゲーム／Discordのサーバー・窓口（くわしくは下の「業種」「ゲーム・Discordのサーバー」「窓口」）
alter table public.companies add column if not exists industries text[]  not null default '{}';          -- 中分類のコード（25まで）
alter table public.companies add column if not exists servers    jsonb   not null default '[]'::jsonb;  -- ゲーム・Discordのサーバー（5つまで）
alter table public.companies add column if not exists desk_on    boolean not null default true;         -- 窓口で相談を受け付ける
alter table public.companies add column if not exists desk_note  text    not null default '';           -- 窓口の案内（受付時間など）
-- 上場（くわしくは下の「上場と株の売買」）：上場しているか・株の注文と取引・上場の申請
alter table public.companies add column if not exists listed    boolean not null default false;
alter table public.companies add column if not exists listed_at timestamptz;
create table if not exists public.stock_orders (
  id         bigserial primary key,
  company_id int  not null references public.companies(id) on delete cascade,   -- 株の会社
  exch_id    int  references public.companies(id) on delete set null,           -- 取引所（国営）
  user_id    uuid not null references public.profiles(id) on delete cascade,
  side       text not null check (side in ('buy', 'sell')),
  price      bigint not null check (price > 0),                                 -- 1株あたりの X
  qty        bigint not null check (qty > 0),
  remain     bigint not null check (remain >= 0),
  locked     bigint not null default 0,                                         -- 買い：まだ預かっている X（手数料こみ）
  fee_pct    numeric not null default 0,                                        -- 注文したときの手数料（%）
  status     text not null default 'open',                                      -- open / done / canceled
  created_at timestamptz not null default now()
);
create table if not exists public.stock_trades (
  id         bigserial primary key,
  company_id int  not null references public.companies(id) on delete cascade,
  exch_id    int  references public.companies(id) on delete set null,
  buy_order  bigint not null,
  sell_order bigint not null,
  buyer      uuid not null references public.profiles(id) on delete cascade,
  seller     uuid not null references public.profiles(id) on delete cascade,
  price      bigint not null,
  qty        bigint not null,
  value      bigint not null,
  fee_buy    bigint not null default 0,
  fee_sell   bigint not null default 0,
  created_at timestamptz not null default now()
);
-- 株価：いまの起点（上場・決めなおし）からの最後の取引の値段。まだなければ公開価格。上場していなければ最後の取引
create or replace function public._stock_last(cid_int int) returns bigint
language sql stable set search_path = public as $$
  select coalesce(
    (select t.price from stock_trades t where t.company_id = c.id and t.created_at >= coalesce(c.price_from, c.listed_at, '-infinity'::timestamptz) order by t.id desc limit 1),
    case when c.listed then c.ipo_price end,
    (select t.price from stock_trades t where t.company_id = c.id order by t.id desc limit 1))
  from companies c where c.id = cid_int
$$;

create table if not exists public.stock_list_apps (
  id         bigserial primary key,
  company_id int  not null references public.companies(id) on delete cascade,
  owner      uuid references public.profiles(id) on delete set null,
  note       text not null default '',
  status     text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  reason     text,
  decided_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index if not exists stock_orders_book_idx on public.stock_orders(company_id, side, status, price, id);
create index if not exists stock_orders_user_idx on public.stock_orders(user_id, status);
create index if not exists stock_trades_corp_idx on public.stock_trades(company_id, id desc);
create index if not exists stock_trades_time_idx on public.stock_trades(created_at);
create index if not exists stock_list_apps_corp_idx on public.stock_list_apps(company_id, status);
alter table public.stock_orders enable row level security;
alter table public.stock_trades enable row level security;
alter table public.stock_list_apps enable row level security;
revoke all on public.stock_orders, public.stock_trades, public.stock_list_apps from anon, authenticated;

-- 企業の評価（くわしくは下の「企業の評価」）：評価の表と、会社の平均
create table if not exists public.corp_reviews (
  company_id int not null references public.companies(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  stars      int not null check (stars between 1 and 5),
  week       date not null,
  updated_at timestamptz not null default now(),
  primary key (company_id, user_id)
);
-- その週の月曜（日本時間）
create or replace function public._week_start(ts timestamptz) returns date
language sql stable as $$ select date_trunc('week', ts at time zone 'Asia/Tokyo')::date $$;

-- 会社の評価（平均・人数・★ごとの人数・良企業／優良企業）
create or replace function public._corp_rating(cid_int int) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('avg', case when count(*) > 0 then round(avg(stars)::numeric, 1) end, 'n', count(*),
    'dist', jsonb_build_array(count(*) filter (where stars = 1), count(*) filter (where stars = 2), count(*) filter (where stars = 3),
                              count(*) filter (where stars = 4), count(*) filter (where stars = 5)),
    'grade', case when count(*) >= 3 and avg(stars) >= 4.7 then '優良企業' when count(*) >= 3 and avg(stars) >= 4.1 then '良企業' end)
  from corp_reviews where company_id = cid_int $$;


-- 自社株（その会社が自分で持っている株）の数
create or replace function public._self_shares(cid_int int) returns bigint
language plpgsql stable set search_path = public as $$
begin
  return coalesce((select h.shares from companies c join corp_holders h on h.company_id = c.id and h.user_id = c.holder where c.id = cid_int), 0);
end $$;
-- 親会社：株（自社株をのぞく）の半分より多くを持っている会社（なければ行なし）
create or replace function public._corp_parent(cid_int int) returns table(id int, cid text, name text, pct numeric)
language plpgsql stable set search_path = public as $$
#variable_conflict use_column
begin
  return query
  select p.id, p.cid, p.name, round(h.shares * 100.0 / greatest(x.shares - _self_shares(x.id), 1), 1)
    from companies x join corp_holders h on h.company_id = x.id
    join companies p on p.holder = h.user_id and p.id <> x.id and p.status in ('active', 'suspended')
   where x.id = cid_int and h.shares * 2 > x.shares - _self_shares(x.id)
   order by h.shares desc limit 1;
end $$;
-- 子会社の一覧
create or replace function public._corp_subs(cid_int int) returns jsonb
language plpgsql stable set search_path = public as $$
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('cid', x.cid, 'name', x.name,
                    'pct', round(h.shares * 100.0 / greatest(x.shares - _self_shares(x.id), 1), 1)) order by x.id), '[]'::jsonb)
            from companies p join corp_holders h on h.user_id = p.holder
            join companies x on x.id = h.company_id and x.id <> p.id and x.status in ('active', 'suspended')
           where p.id = cid_int and h.shares * 2 > x.shares - _self_shares(x.id));
end $$;

create or replace function public._corp_card(c companies, u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'form', c.form, 'kind', c.kind, 'description', c.description,
    'owner', case when c.ai then (select s.name from ai_staff s where s.company_id = c.id and s.role = 'ceo' and s.left_on is null order by s.id limit 1)
                  else (select nickname from profiles where id = c.owner) end,
    'owner_badge', case when c.ai then null else _badge(c.owner) end, 'ai', c.ai, 'rate', c.rate, 'status', c.status,
    'exchange', c.cid = (select value from app_settings where key = 'exchange_cid'), 'official', c.official, 'acct_mode', c.acct_mode,
    'acct_need_check', c.acct_need_check, 'loan_on', c.loan_on, 'loan_need_acct', c.loan_need_acct, 'loan_need_check', c.loan_need_check,
    'pinned', exists (select 1 from corp_pins where user_id = u and company_id = c.id),
    'closed_at', case when c.closed_at is null then null else _dlabel(c.closed_at) end,
    'rating', _corp_rating(c.id),
    'cert', c.status = 'active' and coalesce(c.cert_until > _now(), false),
    'cert_until', case when c.status = 'active' and c.cert_until > _now() then _dlabel(c.cert_until) end,
    'industries', c.industries,
    'servers', case when c.status in ('active', 'suspended') then c.servers else '[]'::jsonb end,
    'desk_on', c.desk_on and c.status in ('active', 'suspended'),
    'desk_note', case when c.status in ('active', 'suspended') then c.desk_note else '' end,
    'listed', c.listed and c.status in ('active', 'suspended'),
    'price', case when c.listed then _stock_last(c.id) end,
    'parent', (select jsonb_build_object('cid', z.cid, 'name', z.name, 'pct', z.pct) from _corp_parent(c.id) z),
    'mine', c.owner = u)
$$;

-- 会社をさがす（名前の一部・ID・説明・業種の名前・サーバーの名前）。p_ind：業種でしぼる（大分類 A〜T か中分類 01〜99）
drop function if exists public.corp_search(text);
create or replace function public.corp_search(p_q text, p_ind text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); q text := btrim(coalesce(p_q, '')); ind text := upper(btrim(coalesce(p_ind, '')));
begin
  return (select coalesce(jsonb_agg(_corp_card(c, u) order by (c.status in ('active', 'suspended')) desc, c.name), '[]'::jsonb) from (
    select * from companies x
     where x.status in ('active', 'suspended', 'closed', 'bankrupt')
       and (q = '' or x.name ilike '%' || q || '%' or x.cid = split_part(q, '-', 1) or x.description ilike '%' || q || '%'
            or exists (select 1 from industry_codes ic where ic.code = any(x.industries) and ic.name ilike '%' || q || '%')
            or (x.status in ('active', 'suspended') and exists (select 1 from jsonb_array_elements(x.servers) sv
                                                                 where sv->>'name' ilike '%' || q || '%' or sv->>'game' ilike '%' || q || '%')))
       and (ind = '' or ind = any(x.industries)
            or (ind ~ '^[A-T]$' and exists (select 1 from industry_codes ic where ic.code = any(x.industries) and ic.major = ind)))
     order by (x.status in ('active', 'suspended')) desc, x.name limit 50) c);
end $$;

create or replace function public.corp_pins() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return (select coalesce(jsonb_agg(_corp_card(c, u) order by c.name), '[]'::jsonb)
            from companies c join corp_pins p on p.company_id = c.id and p.user_id = u where c.status in ('active', 'suspended'));
end $$;

create or replace function public.corp_pin(p_cid text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); c companies;
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
declare u uuid := _me_g(); c companies; acct bank_accounts;
begin
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended', 'closed', 'bankrupt');
  if not found then raise exception '会社が見つかりません'; end if;
  if c.status in ('closed', 'bankrupt') then   -- 廃業・倒産した会社：名前・説明・社長・評価だけ
    return _corp_card(c, u) || jsonb_build_object('items', '[]'::jsonb, 'account', null, 'packs', '[]'::jsonb, 'loans', '[]'::jsonb,
                                                 'shares', 0, 'holders', '[]'::jsonb, 'balance', _bal(u));
  end if;
  if c.kind = '銀行' then perform _bank_accrue(c.id, u); end if;
  select * into acct from bank_accounts where company_id = c.id and user_id = u;
  return _corp_card(c, u) || jsonb_build_object(
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'price', price, 'description', description) order by id), '[]'::jsonb)
                from corp_items where company_id = c.id and active),
    'account', case when acct.user_id is null then null else jsonb_build_object('balance', acct.balance, 'interest_total', acct.interest_total, 'status', acct.status) end,
    'packs', (select coalesce(jsonb_agg(_pack_json(lp) order by lp.amount), '[]'::jsonb) from loan_packs lp where lp.company_id = c.id and lp.active and c.loan_on),
    'loans', (select coalesce(jsonb_agg(_loan_json(l) order by l.id desc), '[]'::jsonb) from loans l
               where l.company_id = c.id and l.user_id = u and l.status in ('pending', 'active')),
    'shares', c.shares, 'holders', _corp_holders(c.id), 'subs', _corp_subs(c.id),
    'horse_auction', c.id::text is not distinct from (select value from app_settings where key = 'horse_co'),
    'desk_mine', (select count(*) from desk_threads t where t.company_id = c.id and t.user_id = u),
    'desk_staff', _desk_staff(c.id, u),
    'staff', case when c.ai then (select coalesce(jsonb_agg(jsonb_build_object('name', s.name, 'title', s.title, 'desk', s.desk, 'since', _dlabel(_jday_start(s.joined)))
                                   order by (s.role = 'ceo') desc, s.id), '[]'::jsonb) from ai_staff s where s.company_id = c.id and s.left_on is null) end,
    'balance', _bal(u));
end $$;

-- 買う（代金は会社へ。手数料1%・最低1 Xは買う人が払って国庫へ）
create or replace function public.corp_buy(p_item bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); it corp_items; c companies; me profiles; fee bigint; tax bigint; okday timestamptz; oid bigint;
begin
  select * into it from corp_items where id = p_item and active;
  if not found then raise exception 'その商品は売っていません'; end if;
  select * into c from companies where id = it.company_id and status = 'active';
  if not found then raise exception 'この会社はいま営業していません（休業中など）'; end if;
  if c.owner = u then raise exception '自分の会社の商品は買えません'; end if;
  select * into me from profiles where id = u for update;
  okday := coalesce(me.ok7_at, me.created_at + interval '7 days');
  if _now() < okday then raise exception '登録から7日たつまで買い物はできません（%から）', _dlabel(okday); end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので買えません'; end if;
  fee := _xfer_fee(it.price);
  if me.balance < it.price + fee then
    raise exception 'AiliNaXが足りません（手数料 % X をふくめて % X 必要です）', fee, it.price + fee;
  end if;
  tax := _ctax(it.price);                         -- 消費税（値段にふくまれる。会社に入る額から国庫へ）
  update profiles set balance = balance - (it.price + fee) where id = u;
  update treasury set balance = balance + fee + tax, fee_total = fee_total + fee, consumption_total = consumption_total + tax where id = 1;
  insert into corp_orders(item_id, company_id, buyer, item_name, price, fee, tax, note)
  values (it.id, c.id, u, it.name, it.price, fee, tax, nullif(left(btrim(coalesce(p_note, '')), 200), '')) returning id into oid;
  perform _corp_move(c.id, it.price - tax, 'sale', format('「%s」の売上（注文 #%s・消費税 %s X をのぞく）', it.name, oid, _fmt(tax)));
  perform _log(u, 'buy', it.price + fee, 0, jsonb_build_object('company', c.name, 'item', it.name, 'order', oid, 'tax', tax));
  perform _notice(c.owner, format('【注文 #%s】%s さんが「%s」を %s X で買いました（消費税 %s X をのぞいた %s X が会社に入りました）。会社のページから品物を渡してください。',
                                  oid, me.nickname, it.name, _fmt(it.price), _fmt(tax), _fmt(it.price - tax)));
  return jsonb_build_object('order', oid, 'price', it.price, 'fee', fee, 'tax', tax, 'balance', _bal(u));
end $$;

create or replace function public.my_orders() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'company', c.name, 'cid', c.cid, 'item', o.item_name,
            'price', o.price, 'fee', o.fee, 'tax', o.tax, 'note', o.note, 'status', o.status, 'at', _dlabel(o.created_at)) order by o.id desc), '[]'::jsonb)
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
declare u uuid := _me_g(); r record;
begin
  for r in select company_id from bank_accounts where user_id = u and status = 'active' loop perform _bank_accrue(r.company_id, u); end loop;
  return jsonb_build_object('accounts', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'rate', c.rate, 'balance', a.balance,
            'interest_total', a.interest_total, 'active', c.status = 'active', 'status', a.status) order by c.name), '[]'::jsonb)
            from bank_accounts a join companies c on c.id = a.company_id where a.user_id = u),
    'loans', my_loans());
end $$;

-- 持っている会社の数（社長として。審査中・活動中・休業中。国営・AIの会社はのぞく）と、持てる数（1人5社・管理者と副管理者は15社）
create or replace function public._corp_owned(u uuid) returns int
language sql stable set search_path = public as $$
  select count(*)::int from companies where owner = u and status in ('pending', 'active', 'suspended') and not official and not ai $$;
create or replace function public._corp_max(u uuid) returns int
language sql stable set search_path = public as $$ select case when _role(u) in ('admin', 'sub') then 15 else 5 end $$;

-- 企業の申請
drop function if exists public.corp_apply(text, text, text);
drop function if exists public.corp_apply(text, text, boolean, text, text);
create or replace function public.corp_apply(p_name text, p_form text, p_pre boolean, p_kind text, p_desc text, p_inds text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); base text := btrim(coalesce(p_name, '')); nm text; inds text[];
begin
  if char_length(base) < 1 or char_length(base) > 24 then raise exception '会社名は1〜24文字です'; end if;
  if p_form not in ('株式会社', '有限会社', '合同会社') then raise exception '会社の形（株式会社・有限会社・合同会社）をえらんでください'; end if;
  if base ~ '(株式会社|有限会社|合同会社|合資会社|合名会社)' then raise exception '会社名には「株式会社」などを入れないでください（下でえらべます）'; end if;
  if p_kind not in ('一般', '銀行', '証券') then raise exception '会社の種類をえらんでください'; end if;
  if p_kind = '銀行' and p_form <> '株式会社' then raise exception '銀行は株式会社だけです'; end if;
  if p_kind = '証券' and p_form <> '株式会社' then raise exception '証券会社は株式会社だけです'; end if;
  inds := _ind_norm(p_inds, p_kind, false);
  if p_inds is not null and cardinality(inds) = 0 then raise exception '業種を1つ以上えらんでください'; end if;
  nm := case when coalesce(p_pre, true) then p_form || base else base || p_form end;
  if _corp_owned(u) >= _corp_max(u) then
    raise exception '持てる会社は%社までです', _corp_max(u);
  end if;
  if exists (select 1 from companies where lower(name) = lower(nm) and status not in ('rejected', 'closed', 'bankrupt')) then
    raise exception 'その名前の会社はもうあります';
  end if;
  perform _take(u, 1000);
  update treasury set balance = balance + 1000, fee_total = fee_total + 1000 where id = 1;
  perform _log(u, 'corp_fee', 1000, 0, jsonb_build_object('company', nm));
  insert into companies(cid, owner, name, form, kind, description, fee_paid, industries)
  values (_new_ccode(), u, nm, p_form, p_kind, left(coalesce(p_desc, ''), 1000), 1000, inds);
  return my_corps();
end $$;

-- 自分の会社（申請中もふくむ）
create or replace function public.my_corps() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return jsonb_build_object('corps', (select coalesce(jsonb_agg(jsonb_build_object(
      'cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'form', c.form, 'kind', c.kind, 'description', c.description, 'status', c.status, 'reason', c.reason,
      'balance', c.balance, 'rate', c.rate, 'ca', c.ca, 'court_lock', c.court_lock,
      'closed_at', case when c.closed_at is null then null else _dlabel(c.closed_at) end,
      'rating', _corp_rating(c.id),
      'cert_until', case when c.status = 'active' and c.cert_until > _now() then _dlabel(c.cert_until) end,
      'industries', c.industries, 'servers', c.servers, 'desk_on', c.desk_on, 'desk_note', c.desk_note,
      'listed', c.listed, 'listed_at', _dlabel(c.listed_at),
      'price', case when c.listed then _stock_last(c.id) end,
      'list_app', (select jsonb_build_object('status', a.status, 'reason', a.reason, 'note', a.note, 'at', _dlabel(a.created_at))
                     from stock_list_apps a where a.company_id = c.id order by a.id desc limit 1),
      'desk_unread', _desk_unread(c.id), 'desk_open', (select count(*) from desk_threads t where t.company_id = c.id and t.status = 'open'),
      'owed', (select coalesce(sum(price), 0) from corp_orders where company_id = c.id and status = 'paid'),
      'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'price', i.price,
                  'description', i.description, 'active', i.active) order by i.id), '[]'::jsonb) from corp_items i where i.company_id = c.id),
      'orders', (select coalesce(jsonb_agg(z order by z.id desc), '[]'::jsonb) from (
                  select o.id, o.item_name item, o.price, o.tax, o.note, o.status, _dlabel(o.created_at) at, p.nickname buyer, p.account_no buyer_id
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
                 'salary', m.salary, 'paid_total', m.paid_total, 'desk', m.desk) order by m.joined_at), '[]'::jsonb)
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
    ) || jsonb_build_object('parent', (select jsonb_build_object('cid', z.cid, 'name', z.name, 'pct', z.pct) from _corp_parent(c.id) z), 'subs', _corp_subs(c.id))
    order by c.id), '[]'::jsonb) from companies c where c.owner = u and c.status <> 'rejected'),
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
    insert into corp_items(company_id, name, price, description, active, created_at) values (c.id, nm, p_price, left(coalesce(p_desc, ''), 300), coalesce(p_active, true), _now());
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
declare u uuid := _me_g(); q text := btrim(coalesce(p_q, ''));
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
declare u uuid := _me_g();
begin
  return jsonb_build_object(
    'members', (select coalesce(jsonb_agg(jsonb_build_object('company', c.name, 'cid', c.cid, 'role', m.role, 'salary', m.salary,
                  'paid_total', m.paid_total, 'since', _dlabel(m.joined_at), 'status', c.status,
                  'desk', m.desk, 'desk_unread', case when m.desk then _desk_unread(c.id) else 0 end) order by m.joined_at), '[]'::jsonb)
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

-- 管理者：認証マークをつける・のばす（p_days 7〜92日。3ヶ月まで）・取り消す（p_days = 0）
create or replace function public.admin_corp_cert(p_cid text, p_days int, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; untilv timestamptz; note text := nullif(left(btrim(coalesce(p_note, '')), 200), '');
begin
  if _role(u) is distinct from 'admin' then raise exception '認証マークをつけられるのは管理者だけです'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) for update;
  if not found then raise exception '会社が見つかりません'; end if;
  if coalesce(p_days, 0) = 0 then
    if c.cert_until is null or c.cert_until <= _now() then raise exception 'この会社には認証マークがついていません'; end if;
    update companies set cert_until = null, cert_note = null where id = c.id;
    insert into corp_cert_log(company_id, by_user, until, note, at) values (c.id, u, null, note, _now());
    perform _notice_l(c.owner, format('【認証】「%s」の認証マークは取り消されました。%s', c.name, case when note is not null then '理由：' || note else '' end),
                      jsonb_build_object('go', 'corp', 'cid', c.cid), u);
    return _corp_card(c, u) || jsonb_build_object('cert', false, 'cert_until', null);
  end if;
  if c.status <> 'active' then raise exception '認証マークは、営業中の会社だけにつけられます'; end if;
  if p_days < 7 or p_days > 92 then raise exception '期間は1週間（7日）〜3ヶ月です'; end if;
  untilv := least(_now() + make_interval(days => p_days), _now() + interval '3 months');
  update companies set cert_until = untilv, cert_note = note where id = c.id;
  insert into corp_cert_log(company_id, by_user, until, note, at) values (c.id, u, untilv, note, _now());
  perform _notice_l(c.owner, format('【認証】「%s」がサイトの認証を受けました。認証マークは %s までつきます。%s', c.name, _dlabel(untilv),
                    case when note is not null then '（' || note || '）' else '' end), jsonb_build_object('go', 'corp', 'cid', c.cid), u);
  select * into c from companies where id = c.id;
  return _corp_card(c, u);
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
                  'industries', c.industries, 'owner', p.nickname, 'owner_id', p.account_no, 'owner_badge', _badge(p.id), 'mine', c.owner = u, 'at', _dlabel(c.created_at)) order by c.id), '[]'::jsonb)
                  from companies c join profiles p on p.id = c.owner where c.status = 'pending'),
    'active', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'form', c.form, 'kind', c.kind,
                  'owner', case when c.ai then coalesce(_ai_ceo(c.id), '') || '（AI）' else p.nickname end, 'ai', c.ai,
                  'status', c.status, 'court_lock', c.court_lock, 'industries', c.industries, 'servers', jsonb_array_length(c.servers),
                  'cert_until', case when c.status = 'active' and c.cert_until > _now() then _dlabel(c.cert_until) end,
                  'balance', case when rl = 'admin' then c.balance end) order by c.name), '[]'::jsonb)
                  from companies c join profiles p on p.id = c.owner where c.status in ('active', 'suspended')),
    'fx_requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'amount', r.amount, 'contact', r.contact,
                     'nickname', p.nickname, 'uid', p.account_no, 'mine', r.user_id = u,
                     'ca', case when rl = 'admin' then p.ca end, 'at', _dlabel(r.created_at)) order by r.id), '[]'::jsonb)
                     from fx_requests r join profiles p on p.id = r.user_id where r.status = 'pending'),
    'cases', (select coalesce(jsonb_agg(_case_json(cc, u) order by cc.id), '[]'::jsonb) from court_cases cc where cc.status = 'open'),
    'list_apps', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'cid_full', _cfull(c), 'name', c.name, 'owner', p.nickname, 'owner_id', p.account_no,
                    'owner_badge', _badge(p.id), 'mine', c.owner = u, 'shares', c.shares, 'holders', (select count(*) from _holdings(c.id)),
                    'per_share', case when rl = 'admin' then round(c.balance::numeric / greatest(c.shares, 1), 2) end,
                    'rating', _corp_rating(c.id), 'note', a.note, 'at', _dlabel(a.created_at), 'since', _dlabel(c.decided_at)) order by a.id), '[]'::jsonb)
                    from stock_list_apps a join companies c on c.id = a.company_id join profiles p on p.id = c.owner where a.status = 'pending'),
    'listed', _stock_list(),
    'fee_pct', _fx_fee_pct());
  if rl = 'admin' then
    r := r || jsonb_build_object(
      'treasury', to_jsonb(tr),
      'supply', (select coalesce(sum(balance), 0) from profiles),
      'corp_money', (select coalesce(sum(balance), 0) from companies),
      'bank_money', (select coalesce(sum(balance), 0) from bank_accounts),
      'order_money', (select coalesce(sum(locked), 0) from stock_orders where side = 'buy' and status = 'open')
                     + (select coalesce(sum(remain), 0) from fx_orders where side = 'sell' and status = 'open'),
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
alter table public.invoices add column if not exists tax bigint;   -- 払ったときの消費税
create or replace function public._inv_json(i invoices) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', i.id, 'amount', i.amount, 'memo', i.memo, 'status', i.status,
    'tax', coalesce(i.tax, _ctax(i.amount)), 'net', i.amount - coalesce(i.tax, _ctax(i.amount)),
    'fee', _xfer_fee(i.amount - _ctax(i.amount)), 'at', _dlabel(i.created_at),
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
declare u uuid := _me_g();
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
declare u uuid := _me(); i invoices; to_id text; payer text; notify uuid; ctx bigint;
begin
  select * into i from invoices where id = p_id for update;
  if not found or not (coalesce(i.to_user = u, false) or coalesce(i.to_comp in (select id from companies where owner = u), false)) then raise exception '請求が見つかりません'; end if;
  if i.status <> 'open' then raise exception 'この請求はもう終わっています'; end if;
  to_id := coalesce((select account_no from profiles where id = i.from_user), (select cid from companies where id = i.from_comp and status = 'active'));
  if to_id is null then raise exception '請求した会社が活動していないので払えません'; end if;
  -- 消費税（請求額にふくまれる）：相手には消費税を引いた額を送り、消費税は払う側から国庫へ（払う額の合計は同じ）
  ctx := _ctax(i.amount);
  if i.to_user is not null then
    perform transfer_send(to_id, i.amount - ctx);
    if ctx > 0 then
      update profiles set balance = balance - ctx where id = u and balance >= ctx;
      if not found then raise exception 'AiliNaXが足りません（消費税 % X）', ctx; end if;
      perform _log(u, 'ctax', ctx, 0, jsonb_build_object('invoice', i.id));
    end if;
    payer := (select nickname from profiles where id = u) || ' さん';
  else
    perform corp_send((select cid from companies where id = i.to_comp), to_id, i.amount - ctx);
    if ctx > 0 then perform _corp_move(i.to_comp, -ctx, 'ctax', format('請求 #%s の消費税', i.id)); end if;
    payer := '会社「' || (select name from companies where id = i.to_comp) || '」';
  end if;
  if ctx > 0 then update treasury set balance = balance + ctx, consumption_total = consumption_total + ctx where id = 1; end if;
  update invoices set status = 'paid', done_at = _now(), tax = ctx where id = i.id;
  notify := coalesce(i.from_user, (select owner from companies where id = i.from_comp));
  perform _notice(notify, format('【請求】%s が請求 #%s（%s X%s）を払いました（消費税 %s X をのぞいた %s X が入りました）。', payer, i.id, _fmt(i.amount),
    case when i.memo <> '' then '・' || i.memo else '' end, _fmt(ctx), _fmt(i.amount - ctx)));
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
-- 全部ゆずる・全部売るとき、いったん0になってから行を消すので、0までは許す
alter table public.corp_holders drop constraint if exists corp_holders_shares_check;
alter table public.corp_holders add constraint corp_holders_shares_check check (shares >= 0);
delete from public.corp_holders where shares = 0;
-- 株主がいない活動中の会社は、社長が全部持っていることにする
insert into public.corp_holders(company_id, user_id, shares)
select c.id, c.owner, c.shares from public.companies c
 where c.status = 'active' and not exists (select 1 from public.corp_holders h where h.company_id = c.id);

create or replace function public._corp_holders(cid_int int) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('nickname', coalesce(hc.name, p.nickname), 'uid', p.account_no,
           'badge', case when hc.id is null then _badge(p.id) end, 'ai', p.ai is not null and hc.id is null, 'shares', h.n,
           'pct', round(h.n * 100.0 / greatest(c.shares, 1), 2),
           'corp', case when hc.id is not null then jsonb_build_object('cid', hc.cid, 'name', hc.name, 'self', hc.id = cid_int) end)
           order by h.n desc, p.nickname), '[]'::jsonb)
    from (select user_id, sum(n)::bigint n, sum(s)::bigint s from (
            select user_id, shares n, 0 s from corp_holders where company_id = cid_int
            union all
            select user_id, remain, remain from stock_orders where company_id = cid_int and side = 'sell' and status = 'open') y
          group by user_id) h
    join profiles p on p.id = h.user_id join companies c on c.id = cid_int left join companies hc on hc.holder = h.user_id
$$;
-- 持ち株（売り注文に出している分もふくめる）。配当・分配に使う
create or replace function public._holdings(cid_int int) returns table(user_id uuid, shares bigint)
language sql stable set search_path = public as $$
  select user_id, sum(n)::bigint from (
    select user_id, shares n from corp_holders where company_id = cid_int
    union all
    select user_id, remain from stock_orders where company_id = cid_int and side = 'sell' and status = 'open') y
  group by user_id
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
  if c.listed then raise exception '上場している会社は、発行株数を変えられません（株主を守るため）'; end if;
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
declare u uuid := _me(); c companies; mine bigint; t record; me profiles; to_u uuid; tc companies;
begin
  if (select official from companies where cid = _cid_norm(p_cid)) then raise exception '国営の会社には株がありません'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません'; end if;
  select shares into mine from corp_holders where company_id = c.id and user_id = u for update;
  if p_shares is null or p_shares < 1 then raise exception 'ゆずる数を入れてください'; end if;
  if coalesce(mine, 0) < p_shares then raise exception 'ゆずれるのは持っている % までです', coalesce(mine, 0); end if;
  select * into t from _find_id(p_to);
  if t.rid = u then raise exception '自分にはゆずれません'; end if;
  if t.rid is null then   -- 会社にゆずる：その会社の持ち株に（自分の会社・その会社自身＝自社株も）
    to_u := _corp_hold_uid(t.rcomp);
    select * into tc from companies where id = t.rcomp;
  else
    to_u := t.rid;
  end if;
  select * into me from profiles where id = u;
  update corp_holders set shares = shares - p_shares where company_id = c.id and user_id = u;
  delete from corp_holders where company_id = c.id and shares <= 0;
  perform _add_shares(c.id, to_u, p_shares);
  if tc.id is not null then
    insert into corp_ledger(company_id, kind, amount, memo, balance_after)
    values (tc.id, 'shares_in', 0, format('「%s」の%s %s を受け取った', c.name, case when c.form = '株式会社' then '株' else '出資' end, _fmt(p_shares)), tc.balance);
    if tc.owner <> u then
      perform _notice(tc.owner, format('【株】%s（ID %s）から、会社「%s」が「%s」の%s %s をゆずり受けました。', me.nickname, me.account_no, tc.name, c.name,
                      case when c.form = '株式会社' then '株' else '出資' end, _fmt(p_shares)));
    end if;
  else
    perform _notice(to_u, format('【株】%s（ID %s）から「%s」の%s %s をゆずり受けました。', me.nickname, me.account_no, c.name,
                    case when c.form = '株式会社' then '株' else '出資' end, _fmt(p_shares)));
  end if;
  return my_stocks();
end $$;

-- 自分の持ち株
create or replace function public.my_stocks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return jsonb_build_object('stocks', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'form', c.form, 'status', c.status,
           'shares', coalesce(h.shares, 0), 'total', c.shares, 'pct', round((coalesce(h.shares, 0) + h.on_sale) * 100.0 / greatest(c.shares, 1), 2),
           'on_sale', h.on_sale, 'listed', c.listed,
           'price', case when c.listed then _stock_last(c.id) end,
           'owner', case when c.ai then _ai_ceo(c.id) else (select nickname from profiles where id = c.owner) end, 'mine', c.owner = u, 'ai', c.ai,
           'parent', (select jsonb_build_object('cid', z.cid, 'name', z.name, 'pct', z.pct) from _corp_parent(c.id) z),
           'dividend_total', (select coalesce(sum(payout), 0) from tx_log where user_id = u and game = 'dividend' and detail->>'company_id' = c.id::text))
           order by c.name), '[]'::jsonb)
         from (select company_id, sum(n)::bigint shares, sum(s)::bigint on_sale from (
                 select company_id, shares n, 0 s from corp_holders where user_id = u
                 union all
                 select company_id, 0, remain from stock_orders where user_id = u and side = 'sell' and status = 'open') y group by company_id) h
         join companies c on c.id = h.company_id where c.status in ('active', 'suspended')),
    'offers_in', (select coalesce(jsonb_agg(_offer_json(o) order by o.id desc), '[]'::jsonb) from share_offers o where o.to_user = u and o.status = 'open'),
    'offers_out', (select coalesce(jsonb_agg(_offer_json(o) order by o.id desc), '[]'::jsonb) from (
                    select * from share_offers where from_user = u order by (status = 'open') desc, id desc limit 20) o),
    'corps', (select coalesce(jsonb_agg(jsonb_build_object('cid', f.cid, 'cid_full', _cfull(f), 'name', f.name, 'status', f.status, 'balance', f.balance,
               'stocks', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'form', c.form, 'status', c.status, 'shares', h.shares, 'total', c.shares,
                            'pct', round(h.shares * 100.0 / greatest(c.shares, 1), 2), 'listed', c.listed, 'price', case when c.listed then _stock_last(c.id) end, 'ai', c.ai,
                            'self', c.id = f.id, 'sub', c.id <> f.id and h.shares * 2 > c.shares - _self_shares(c.id))
                            order by (c.id = f.id) desc, c.name), '[]'::jsonb)
                          from corp_holders h join companies c on c.id = h.company_id and c.status in ('active', 'suspended')
                         where f.holder is not null and h.user_id = f.holder),
               'offers_in', (select coalesce(jsonb_agg(_offer_json(o) order by o.id desc), '[]'::jsonb) from share_offers o
                              where f.holder is not null and o.to_user = f.holder and o.status = 'open'),
               'offers_out', (select coalesce(jsonb_agg(_offer_json(o) order by o.id desc), '[]'::jsonb) from (
                               select * from share_offers where f.holder is not null and from_user = f.holder order by (status = 'open') desc, id desc limit 20) o))
             order by f.id), '[]'::jsonb)
             from companies f where f.owner = u and f.status in ('active', 'suspended') and not f.ai),
    'balance', _bal(u));
end $$;

-- 配当：会社のお金から、持ち株の数に合わせて株主に配る（端数は会社に残る）。もらった人の所得になる
create or replace function public.corp_dividend(p_cid text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; h record; amt bigint; total bigint := 0; n int := 0; r jsonb; hc companies; base bigint;
begin
  if (select official from companies where cid = _cid_norm(p_cid)) then raise exception '国営の会社は配当を出せません'; end if;
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  if p_amount is null or p_amount < 1 or p_amount > c.balance then raise exception '配当に使えるのは会社のお金 % X までです', c.balance; end if;
  base := c.shares - _self_shares(c.id);   -- 自社株には配当を出さない（ほかの株主で分ける）
  if base < 1 then raise exception '配当を受け取れる株主がいません（自社株だけです）'; end if;
  for h in select * from _holdings(c.id) loop
    if c.holder is not null and h.user_id = c.holder then continue; end if;
    amt := floor(p_amount::numeric * h.shares / base);
    if amt > 0 then
      select * into hc from companies where holder = h.user_id;
      if hc.id is not null then   -- 株主が会社：会社のお金に
        perform _corp_move(hc.id, amt, 'dividend_in', format('「%s」からの配当', c.name));
        perform _notice(hc.owner, format('【配当】会社「%s」の持ち株に、「%s」から配当 %s X が入りました（会社のお金）。', hc.name, c.name, _fmt(amt)));
      else
        perform _give(h.user_id, amt);
        perform _log(h.user_id, 'dividend', 0, amt, jsonb_build_object('company', c.name, 'company_id', c.id));
        perform _notice(h.user_id, format('【配当】「%s」から配当 %s X が入りました。', c.name, _fmt(amt)));
      end if;
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
  if not c.official and _corp_owned(t.rid) >= _corp_max(t.rid) then
    raise exception 'その人はもう%社の社長です（持てる会社は%社まで）', _corp_owned(t.rid), _corp_max(t.rid);
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
declare u uuid := _me_g();
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
declare u uuid := _me_g();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'body', z.body, 'at', _dlabel(z.created_at),
            'ts', floor(extract(epoch from z.created_at) * 1000), 'nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id),
            'mine', z.user_id = u, 'friend', _is_friend(u, z.user_id), 'names', _mention_names(z.body),
            'to_me', (select account_no from profiles where id = u) = any(_mention_ids(z.body)),
            'asked', exists (select 1 from friends f where f.from_user = u and f.to_user = z.user_id and f.status = 'pending'))
            order by z.id desc), '[]'::jsonb)
    from (select * from posts
           where (p_before is null or id < p_before)
             and case coalesce(p_scope, 'all') when 'all' then true
                      when 'mention' then (select account_no from profiles where id = u) = any(_mention_ids(body))
                      else user_id = u or _is_friend(u, user_id) end
           order by id desc limit 30) z join profiles p on p.id = z.user_id);
end $$;

create or replace function public.tl_post(p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); b text := btrim(coalesce(p_body, '')); pid bigint;
begin
  if char_length(b) < 1 then raise exception '何か書いてください'; end if;
  if char_length(b) > 140 then raise exception '140文字までです'; end if;
  if exists (select 1 from posts where user_id = u and created_at > _now() - interval '10 seconds') then
    raise exception '連続の投稿は10秒あけてください';
  end if;
  if (select count(*) from posts where user_id = u and created_at > _now() - interval '1 day') >= 100 then
    raise exception '投稿は1日100件までです';
  end if;
  insert into posts(user_id, body, created_at) values (u, b, _now()) returning id into pid;
  perform _mention_notify(u, b, 'TL', jsonb_build_object('go', 'tl', 'post', pid));
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
  perform _me_g();
  return jsonb_build_object('exchanges', _fx_exchanges(),
    'fx', (select _fx_market(c.id) from _fx_pick(null) c where c.id is not null), 'stocks', _stock_list());
end $$;

-- 取引所の画面（相場＋自分の残高・注文・交換申請）
drop function if exists public.fx_state();
create or replace function public.fx_state(p_exch text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); xc companies := _fx_pick(p_exch);
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
-- 為替の注文を出して、合う注文とすぐ約定する（中で使う。画面からの注文も、国の介入もこれを通る）。注文の id を返す。ioc なら残りは取り消す
create or replace function public._fx_exec(u uuid, xc companies, p_side text, p_price numeric, p_qty bigint, ioc boolean) returns bigint
language plpgsql set search_path = public as $$
declare o fx_orders; m fx_orders; bo fx_orders; so fx_orders;
  q bigint; v bigint; ex numeric; fx bigint; fc bigint; lockamt bigint; pct numeric := xc.fx_fee; tot_x bigint := 0; tot_c bigint := 0;
begin
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
  if ioc and o.remain > 0 then perform _fx_cancel_order(o.id); end if;   -- すぐ合わなかった残りは取り消す
  if tot_x > 0 then perform _corp_move(xc.id, tot_x, 'fx_fee', format('取引の手数料 %s X', _fmt(tot_x))); end if;
  if tot_c > 0 then
    update companies set ca = ca + tot_c where id = xc.id;
    insert into corp_ledger(company_id, kind, amount, memo, balance_after)
    values (xc.id, 'fx_fee', 0, format('取引の手数料 %s CA', _fmt(tot_c)), (select balance from companies where id = xc.id));
  end if;
  return o.id;
end $$;

create or replace function public.fx_order(p_exch text, p_side text, p_price numeric, p_qty bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); xc companies; me profiles; okday timestamptz;
begin
  if p_side not in ('buy', 'sell') then raise exception '買いか売りをえらんでください'; end if;
  if p_price is null or p_price <= 0 or p_price > 1000000000 then raise exception '値段は0より大きく、10億 CA までにしてください'; end if;
  if p_price <> round(p_price, 4) then raise exception '値段は小数第4位までです'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 1000000000 then raise exception '数量は1〜10億 X にしてください'; end if;
  xc := _fx_pick(p_exch);
  if xc.id is null or (coalesce(btrim(p_exch), '') <> '' and xc.cid <> _cid_norm(p_exch)) then raise exception 'その取引所は見つかりません'; end if;
  if xc.status <> 'active' then raise exception '取引所（%）がいま営業していないので、注文できません', xc.name; end if;
  select * into me from profiles where id = u for update;
  okday := coalesce(me.ok7_at, me.created_at + interval '7 days');
  if _now() < okday then raise exception '登録から7日たつまで取引所は使えません（%から）', _dlabel(okday); end if;
  if (select count(*) from fx_orders where user_id = u and status = 'open') >= 30 then raise exception '出せる注文は30件までです'; end if;
  perform _fx_exec(u, xc, p_side, p_price, p_qty, false);
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
  hc companies; selfn bigint; r2 record; given bigint;
begin
  select * into c from companies where id = cid_int for update;
  if not found or c.status not in ('active', 'suspended') then raise exception 'この会社はもう活動していません'; end if;
  label := case when how = 'closed' then '廃業' else '倒産' end;
  for r in select * from desk_threads where company_id = c.id and status = 'open' loop
    update desk_threads set status = 'closed', closed_by = 'gone' where id = r.id;
    perform _notice_l(r.user_id, format('【窓口】「%s」が%sしたため、相談「%s」は終わりました', c.name, label, r.subject), jsonb_build_object('go', 'desk', 't', r.id), null);
  end loop;
  if c.kind = '銀行' then
    perform _bank_accrue_all(c.id);
    select * into c from companies where id = cid_int;
  end if;
  owed_orders := coalesce((select sum(price - tax) from corp_orders where company_id = c.id and status = 'paid'), 0);
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
    amt := floor((r.price - r.tax) * ratio);
    if amt > 0 then perform _corp_move(c.id, -amt, 'refund', format('注文 #%s の返金（%s）', r.id, label)); end if;
    if r.tax > 0 then   -- 消費税は国庫から返す
      update treasury set balance = balance - r.tax, consumption_total = consumption_total - r.tax where id = 1;
      amt := amt + r.tax;
    end if;
    if amt > 0 then
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
  update stock_list_apps set status = 'withdrawn', decided_at = _now() where company_id = c.id and status = 'pending';
  -- 上場していれば上場廃止（株の注文を取り消して、株と預かったお金を返す）
  if c.listed or exists (select 1 from stock_orders where company_id = c.id and status = 'open') then
    perform pg_advisory_xact_lock(7400, c.id);
    perform _stock_delist(c.id, label || 'のため');
  end if;
  -- 請求・求人・社員
  update invoices set status = 'canceled', done_at = _now() where status = 'open' and (from_comp = c.id or to_comp = c.id);
  update corp_jobs set active = false where company_id = c.id;
  update corp_applies set status = 'declined' where status = 'waiting' and job_id in (select id from corp_jobs where company_id = c.id);
  for r in select user_id from corp_members where company_id = c.id loop
    perform _notice(r.user_id, format('【%s】勤め先の「%s」が%sしました。', label, c.name, label));
  end loop;
  delete from corp_members where company_id = c.id;
  -- 残ったお金を株主に（持ち株の割合。自社株の分はのぞく。株主が会社なら会社のお金に。端数は社長）
  selfn := _self_shares(c.id);
  select balance into rest from companies where id = c.id;
  if rest > 0 then
    for r in select * from corp_holders where company_id = c.id and user_id is distinct from c.holder loop
      amt := floor(rest::numeric * r.shares / greatest(c.shares - selfn, 1));
      if amt > 0 then
        select * into hc from companies where holder = r.user_id;
        if hc.id is not null then
          perform _corp_move(hc.id, amt, 'liquidation_in', format('「%s」の残ったお金の分配（%s）', c.name, label));
          perform _notice(hc.owner, format('【%s】「%s」の残ったお金から、会社「%s」が持ち株の割合で %s X を受け取りました（会社のお金）。', label, c.name, hc.name, _fmt(amt)));
        else
          perform _give(r.user_id, amt);
          perform _log(r.user_id, 'liquidation', 0, amt, jsonb_build_object('company', c.name));
          perform _notice(r.user_id, format('【%s】「%s」の残ったお金から、持ち株の割合で %s X を受け取りました。', label, c.name, _fmt(amt)));
        end if;
        total := total + amt; holders := holders + 1;
      end if;
    end loop;
    if rest - total > 0 then
      perform _give(c.owner, rest - total);
      perform _log(c.owner, 'liquidation', 0, rest - total, jsonb_build_object('company', c.name));
    end if;
    perform _corp_move(c.id, -rest, 'liquidation', '残ったお金を株主に分配（' || label || '）');
  end if;
  -- この会社が持っていた、ほかの会社の株：この会社の株主に、持ち株の割合で（自社株の分はのぞく。端数は社長）
  if c.holder is not null then
    update share_offers set status = 'canceled', done_at = _now() where status = 'open' and (from_user = c.holder or to_user = c.holder);
    for r in select h.company_id, h.shares, y.name yname, case when y.form = '株式会社' then '株' else '出資' end yunit
               from corp_holders h join companies y on y.id = h.company_id where h.user_id = c.holder and h.company_id <> c.id order by h.company_id loop
      given := 0;
      for r2 in select * from corp_holders where company_id = c.id and user_id is distinct from c.holder order by shares desc, user_id loop
        amt := floor(r.shares::numeric * r2.shares / greatest(c.shares - selfn, 1));
        if amt > 0 then
          perform _add_shares(r.company_id, r2.user_id, amt);
          given := given + amt;
          select * into hc from companies where holder = r2.user_id;
          if hc.id is not null then
            perform _notice(hc.owner, format('【%s】「%s」が持っていた「%s」の%s %s を、会社「%s」が持ち株の割合で受け取りました。', label, c.name, r.yname, r.yunit, _fmt(amt), hc.name));
          else
            perform _notice(r2.user_id, format('【%s】「%s」が持っていた「%s」の%s %s を、持ち株の割合で受け取りました。', label, c.name, r.yname, r.yunit, _fmt(amt)));
          end if;
        end if;
      end loop;
      if r.shares - given > 0 then
        perform _add_shares(r.company_id, c.owner, r.shares - given);
        perform _notice(c.owner, format('【%s】「%s」が持っていた「%s」の%s %s を、社長として受け取りました（割りきれなかった分）。', label, c.name, r.yname, r.yunit, _fmt(r.shares - given)));
      end if;
      delete from corp_holders where company_id = r.company_id and user_id = c.holder;
    end loop;
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
         reason = left(coalesce(why, ''), 300), closed_at = _now(), court_lock = false, cert_until = null
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
    'from_name', coalesce((select x.name from companies x where x.holder = o.from_user), (select nickname from profiles where id = o.from_user)),
    'from_id', coalesce((select _cfull(x) from companies x where x.holder = o.from_user), (select account_no from profiles where id = o.from_user)),
    'from_corp', exists (select 1 from companies x where x.holder = o.from_user),
    'from_badge', case when exists (select 1 from companies x where x.holder = o.from_user) then null else _badge(o.from_user) end,
    'to_name', coalesce((select x.name from companies x where x.holder = o.to_user), (select nickname from profiles where id = o.to_user)),
    'to_id', coalesce((select _cfull(x) from companies x where x.holder = o.to_user), (select account_no from profiles where id = o.to_user)),
    'to_corp', exists (select 1 from companies x where x.holder = o.to_user))
$$;

create or replace function public.share_offer(p_cid text, p_to text, p_shares bigint, p_price bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; mine bigint; t record; me profiles; to_u uuid; tc companies;
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
  if t.rid = u then raise exception '自分にはゆずれません'; end if;
  if t.rid is null then
    to_u := _corp_hold_uid(t.rcomp);
    select * into tc from companies where id = t.rcomp;
  else
    to_u := t.rid;
  end if;
  select * into me from profiles where id = u;
  if _now() < coalesce(me.ok7_at, me.created_at + interval '7 days') then raise exception '登録から7日たつまで、代金つきの譲渡はできません'; end if;
  if (select count(*) from share_offers where from_user = u and status = 'open') >= 20 then raise exception '返事待ちの申し出は20件までです'; end if;
  insert into share_offers(company_id, from_user, to_user, shares, price, created_at) values (c.id, u, to_u, p_shares, p_price, _now());
  if tc.id is not null then
    perform _notice(tc.owner, format('【株の譲渡】%s（ID %s）から、会社「%s」あてに「%s」の%s %s を %s X でゆずりたいという申し出が来ました。企業タブの「持ち株」から返事できます。',
                    me.nickname, me.account_no, tc.name, c.name, case when c.form = '株式会社' then '株' else '出資' end, _fmt(p_shares), _fmt(p_price)));
  else
    perform _notice(to_u, format('【株の譲渡】%s（ID %s）から「%s」の%s %s を %s X でゆずりたいという申し出が来ました。企業タブの「持ち株」から返事できます。',
                    me.nickname, me.account_no, c.name, case when c.form = '株式会社' then '株' else '出資' end, _fmt(p_shares), _fmt(p_price)));
  end if;
  return my_stocks();
end $$;

-- 申し出に返事する（受ける＝代金を払って株を受け取る）
create or replace function public.share_offer_answer(p_id bigint, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); o share_offers; c companies; me profiles; mine bigint; fee bigint; bc companies; sc companies;
begin
  -- 自分あて、または自分が社長をしている会社あての申し出
  select * into o from share_offers where id = p_id and status = 'open'
     and (to_user = u or to_user in (select holder from companies where owner = u and holder is not null)) for update;
  if not found then raise exception '申し出が見つかりません'; end if;
  select * into c from companies where id = o.company_id;
  select * into bc from companies where holder = o.to_user;     -- 受け取る側が会社
  select * into sc from companies where holder = o.from_user;   -- ゆずる側が会社
  if not p_ok then
    update share_offers set status = 'declined', done_at = _now() where id = o.id;
    perform _notice(coalesce(sc.owner, o.from_user), format('【株の譲渡】「%s」の株の申し出（#%s）は断られました。', c.name, o.id));
    return my_stocks();
  end if;
  if c.status not in ('active', 'suspended') then raise exception 'この会社はもうありません'; end if;
  select * into me from profiles where id = u for update;
  if _now() < coalesce(me.ok7_at, me.created_at + interval '7 days') then raise exception '登録から7日たつまで、代金つきの譲渡は受けられません'; end if;
  select shares into mine from corp_holders where company_id = c.id and user_id = o.from_user for update;
  if coalesce(mine, 0) < o.shares then raise exception '相手がもう、その数の株を持っていません'; end if;
  fee := _xfer_fee(o.price);
  if bc.id is not null then   -- 会社のお金で払う
    if bc.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
    if (select balance from companies where id = bc.id for update) < o.price + fee then
      raise exception '会社のお金が足りません（手数料 % X をふくめて % X 必要です）', fee, o.price + fee;
    end if;
    perform _corp_move(bc.id, -(o.price + fee), 'share_buy', format('「%s」の株 %s を買った（手数料 %s X）', c.name, _fmt(o.shares), _fmt(fee)));
  else
    if _debt(u) > 0 then raise exception '税金の滞納があるので払えません'; end if;
    if me.balance < o.price + fee then raise exception 'AiliNaXが足りません（手数料 % X をふくめて % X 必要です）', fee, o.price + fee; end if;
    update profiles set balance = balance - (o.price + fee) where id = u;
    perform _log(u, 'share_buy', o.price + fee, 0, jsonb_build_object('company', c.name, 'shares', o.shares, 'fee', fee));
  end if;
  update treasury set balance = balance + fee, fee_total = fee_total + fee where id = 1;
  if sc.id is not null then   -- 代金は、ゆずった会社のお金に
    perform _corp_move(sc.id, o.price, 'share_sell', format('「%s」の株 %s を売った', c.name, _fmt(o.shares)));
  else
    perform _give(o.from_user, o.price);
    perform _log(o.from_user, 'share_sell', 0, o.price, jsonb_build_object('company', c.name, 'shares', o.shares));
  end if;
  update corp_holders set shares = shares - o.shares where company_id = c.id and user_id = o.from_user;
  delete from corp_holders where company_id = c.id and shares <= 0;
  perform _add_shares(c.id, o.to_user, o.shares);
  update share_offers set status = 'done', done_at = _now() where id = o.id;
  perform _notice(coalesce(sc.owner, o.from_user), case
    when bc.id is not null and sc.id is not null then
      format('【株の譲渡】会社「%s」が「%s」の株 %s を %s X で受けました。代金は会社「%s」に入りました。', bc.name, c.name, _fmt(o.shares), _fmt(o.price), sc.name)
    when bc.id is not null then
      format('【株の譲渡】会社「%s」が「%s」の株 %s を %s X で受けました。代金が入りました。', bc.name, c.name, _fmt(o.shares), _fmt(o.price))
    when sc.id is not null then
      format('【株の譲渡】%s さんが「%s」の株 %s を %s X で受けました。代金は会社「%s」に入りました。', me.nickname, c.name, _fmt(o.shares), _fmt(o.price), sc.name)
    else
      format('【株の譲渡】%s さんが「%s」の株 %s を %s X で受けました。代金が入りました。', me.nickname, c.name, _fmt(o.shares), _fmt(o.price)) end);
  return my_stocks() || jsonb_build_object('balance', _bal(u));
end $$;

create or replace function public.share_offer_cancel(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  update share_offers set status = 'canceled', done_at = _now()
   where id = p_id and status = 'open'
     and (from_user = u or from_user in (select holder from companies where owner = u and holder is not null));   -- 自分の会社から出した申し出も
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
declare u uuid := _me_g();
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
  if _now() < coalesce(me.ok7_at, me.created_at + interval '7 days') then raise exception '登録から7日たつまで借りられません'; end if;
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
declare u uuid := _me_g(); r record;
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
-- 対戦ゲーム（オセロ・チェス・将棋・ワンカード・麻雀）
--   部屋：主催が作る（ゲーム・持ち時間・招待・観戦の賭けあり／なし）。だれでも入れる部屋と、IDで招待した人だけの部屋
--   オセロ・チェス・将棋：ふたりそろうと始まる（先手・後手はランダム）。持ち時間は1人ずつ（最大3時間）。切れたら負け
--     本人どうしは賭けない（無料）。観戦する人は、どちらが勝つかに賭けられる（山分け。国庫が5%。登録から7日たってから）
--     ・賭けられるのは10手目まで（それ以降は締め切り）・対局している本人は賭けられない
--     ・引き分け・片方にしか賭けがないときは全部返す
--   ワンカード・麻雀：下の「4人までのゲーム」を見る（本人どうしの賭けだけ。観戦の賭けはなし）
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

-- ---------- ワンカード・麻雀の部屋（4人まで） ----------
--   席は2〜4。主催が「コンピューターを入れて始める」と、空いている席にコンピューターが入る（席はランダム）
--   賭け：主催が1人あたりの賭け金を決める（0は賭けなし）。入るときにはらう。コンピューターは賭けない
--     all（1位の総取り）：人の中でいちばん上の人が全部受け取る（国庫5%）
--     points（点数で分ける）：人どうしで、点数の差に合わせてやりとり（負けは賭け金まで・国庫はもうけの5%）
--   持ち時間：自分が考えているあいだだけ減る。切れたら、そのあとはコンピューターが代わりに打つ
alter table public.game_rooms add column if not exists max_seats  int not null default 2;
alter table public.game_rooms add column if not exists cpu        int[] not null default '{}';         -- コンピューターの席
alter table public.game_rooms add column if not exists auto       int[] not null default '{}';         -- 時間切れ・抜けた人の席
alter table public.game_rooms add column if not exists invites    uuid[] not null default '{}';        -- 招待した人
alter table public.game_rooms add column if not exists stake      bigint not null default 0;           -- 1人の賭け金
alter table public.game_rooms add column if not exists stake_mode text not null default 'all';         -- all / points
alter table public.game_rooms add column if not exists opts       jsonb not null default '{}';
alter table public.game_rooms add column if not exists act_at     timestamptz;                         -- 最後に動いた時刻
alter table public.game_rooms add column if not exists wait_at    timestamptz[] not null default '{}';  -- 席ごとの、考えはじめた時刻
create table if not exists public.game_stakes (
  room_id bigint not null references public.game_rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount  bigint not null check (amount > 0),
  payout  bigint,
  at      timestamptz not null default now(),
  primary key (room_id, user_id)
);
alter table public.game_stakes enable row level security;
revoke all on public.game_stakes from anon, authenticated;

-- ---------- オセロ（8×8。盤は64文字：. 空き / B 黒 / W 白。黒が先手＝席0） ----------
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

-- ---------- ワンカード（UNOと同じ遊び方。2〜4人） ----------
--   カード 0〜107：0〜99 は色つき（色 = id / 25：0 赤・1 黄・2 緑・3 青。id % 25：0 は「0」、1〜9 と 10〜18 は「1〜9」、
--   19・20 スキップ S、21・22 リバース R、23・24 ドロー2 D）。100〜103 ワイルド W、104〜107 ワイルドドロー4 F
--   状態：hands（席ごとの手札）・deck（山札）・pile（捨て札。最後が一番上）・turn・dir（1 / -1）・color（いまの色）
--         drew（引いたカードが出せるので、出すかパスをえらぶ）・drawn・uno（1枚になったのに「ワンカード」と言わなかった席）
--         said（2枚のときに先に「ワンカード」と言った席）・win（番が変わるたびに増える）・log（最近のできごと）
create or replace function public._oc_col(c int) returns int
language sql immutable as $$ select case when c < 100 then c / 25 else -1 end $$;

create or replace function public._oc_sym(c int) returns text
language sql immutable as $$
  select case when c >= 104 then 'F' when c >= 100 then 'W'
              when c % 25 = 0 then '0' when c % 25 <= 9 then (c % 25)::text when c % 25 <= 18 then (c % 25 - 9)::text
              when c % 25 <= 20 then 'S' when c % 25 <= 22 then 'R' else 'D' end $$;

-- 点数（数字はその数・スキップ／リバース／ドロー2は20・ワイルドは50）
create or replace function public._oc_pts(c int) returns int
language sql immutable as $$
  select case when c >= 100 then 50 when c % 25 = 0 then 0 when c % 25 <= 18 then (c % 25 - 1) % 9 + 1 else 20 end $$;

create or replace function public._oc_hand(st jsonb, s int) returns int[]
language sql immutable as $$ select coalesce(array(select jsonb_array_elements_text(st->'hands'->s)::int), '{}') $$;

create or replace function public._oc_arr(st jsonb, k text) returns int[]
language sql immutable as $$ select coalesce(array(select jsonb_array_elements_text(st->k)::int), '{}') $$;

create or replace function public._oc_top(st jsonb) returns int
language sql immutable as $$ select (st->'pile'->>(jsonb_array_length(st->'pile') - 1))::int $$;

-- 出せるか
create or replace function public._oc_ok(st jsonb, hand int[], c int) returns boolean
language plpgsql immutable as $$
declare top int := _oc_top(st); col int := (st->>'color')::int;
begin
  if c >= 104 then return not exists (select 1 from unnest(hand) x where _oc_col(x) = col); end if;   -- いまの色のカードがないときだけ
  if c >= 100 then return true; end if;
  if _oc_col(c) = col then return true; end if;
  return top < 100 and _oc_sym(c) = _oc_sym(top);
end $$;

-- 出せるカード（引いたあとは、引いたカードだけ）
create or replace function public._oc_legal(st jsonb, s int) returns int[]
language plpgsql immutable as $$
declare h int[] := _oc_hand(st, s);
begin
  if coalesce((st->>'drew')::boolean, false) then
    return case when _oc_ok(st, h, (st->>'drawn')::int) then array[(st->>'drawn')::int] else '{}'::int[] end;
  end if;
  return coalesce(array(select x from unnest(h) x where _oc_ok(st, h, x)), '{}');
end $$;

create or replace function public._oc_next(st jsonb, k int) returns int
language sql immutable as $$
  select (((st->>'turn')::int + (st->>'dir')::int * k) % (st->>'n')::int + (st->>'n')::int) % (st->>'n')::int $$;

create or replace function public._oc_log(st jsonb, e jsonb) returns jsonb
language sql immutable as $$
  select jsonb_set(st, '{log}', coalesce((select jsonb_agg(x order by o) from (
           select x, o from jsonb_array_elements(coalesce(st->'log', '[]'::jsonb) || jsonb_build_array(e)) with ordinality t(x, o)
            order by o desc limit 14) z), '[]'::jsonb)) $$;

-- k 枚引く（山札がなくなったら、捨て札の一番上を残して切りなおす）
create or replace function public._oc_draw(st jsonb, s int, k int) returns jsonb
language plpgsql volatile as $$
declare deck int[] := _oc_arr(st, 'deck'); pile int[]; h int[] := _oc_hand(st, s); i int;
begin
  for i in 1..k loop
    if cardinality(deck) = 0 then
      pile := _oc_arr(st, 'pile');
      if cardinality(pile) <= 1 then exit; end if;
      deck := array(select x from unnest(pile[1:cardinality(pile) - 1]) x order by random());
      st := jsonb_set(st, '{pile}', to_jsonb(array[pile[cardinality(pile)]]));
    end if;
    h := h || deck[1]; deck := deck[2:];
  end loop;
  st := jsonb_set(st, '{deck}', to_jsonb(deck));
  return jsonb_set(st, array['hands', s::text], to_jsonb(h));
end $$;

create or replace function public._oc_init(n int) returns jsonb
language plpgsql volatile as $$
declare deck int[]; hands jsonb := '[]'; i int; c int;
begin
  deck := array(select g from generate_series(0, 107) g order by random());
  for i in 0..n - 1 loop hands := hands || jsonb_build_array(to_jsonb(deck[i * 7 + 1:i * 7 + 7])); end loop;
  deck := deck[n * 7 + 1:];
  loop   -- 最初の1枚は数字のカード（ほかは山札の下へ）
    c := deck[1]; deck := deck[2:];
    exit when _oc_sym(c) between '0' and '9';
    deck := deck || c;
  end loop;
  return jsonb_build_object('n', n, 'hands', hands, 'deck', to_jsonb(deck), 'pile', jsonb_build_array(c), 'turn', 0, 'dir', 1,
                            'color', _oc_col(c), 'drew', false, 'drawn', null, 'uno', null, 'said', null, 'win', 1, 'log', '[]'::jsonb, 'over', false);
end $$;

-- 番を進める
create or replace function public._oc_turn(st jsonb, k int) returns jsonb
language sql immutable as $$
  select st || jsonb_build_object('turn', _oc_next(st, k), 'drew', false, 'drawn', null, 'said', null, 'win', (st->>'win')::int + 1) $$;

create or replace function public._oc_act(st jsonb, s int, mv jsonb) returns jsonb
language plpgsql volatile as $$
declare a text := mv->>'a'; h int[]; c int; col int; v int; sym text; n int := (st->>'n')::int;
begin
  if coalesce((st->>'over')::boolean, false) then raise exception 'このゲームはもう終わっています'; end if;
  if a = 'timer' then return st; end if;
  h := _oc_hand(st, s);
  if a = 'catch' then   -- 「ワンカード」と言い忘れた人を指摘する → その人が2枚引く
    if st->>'uno' is null or (st->>'uno')::int = s then raise exception '指摘できる人はいません'; end if;
    v := (st->>'uno')::int;
    st := _oc_draw(st, v, 2);
    return _oc_log(st || jsonb_build_object('uno', null), jsonb_build_object('s', s, 'a', 'catch', 't', v));
  end if;
  if a = 'uno' then   -- 「ワンカード！」
    if st->>'uno' is not null and (st->>'uno')::int = s then
      return _oc_log(st || jsonb_build_object('uno', null), jsonb_build_object('s', s, 'a', 'uno'));
    end if;
    if (st->>'turn')::int = s and cardinality(h) = 2 then
      return _oc_log(st || jsonb_build_object('said', s), jsonb_build_object('s', s, 'a', 'uno'));
    end if;
    raise exception 'いまは言えません（手札が2枚の自分の番、または1枚になった直後）';
  end if;
  if (st->>'turn')::int <> s then raise exception 'いまはあなたの番ではありません'; end if;
  -- 次の人が動いたら、前の人の言い忘れはもう指摘できない
  if st->>'uno' is not null and (st->>'uno')::int <> s then st := st || jsonb_build_object('uno', null); end if;
  if a = 'play' then
    c := (mv->>'c')::int;
    if c is null or not (c = any(h)) then raise exception 'そのカードは持っていません'; end if;
    if coalesce((st->>'drew')::boolean, false) and c <> (st->>'drawn')::int then raise exception '引いたあとは、引いたカードしか出せません'; end if;
    if not _oc_ok(st, h, c) then
      raise exception '%', case when c >= 104 then 'ワイルドドロー4は、いまの色のカードを持っていないときだけ出せます' else 'そのカードは出せません（色か数字・記号を合わせます）' end;
    end if;
    sym := _oc_sym(c);
    if c >= 100 then
      col := (mv->>'col')::int;
      if col is null or col not between 0 and 3 then raise exception '次の色をえらんでください'; end if;
    else col := _oc_col(c); end if;
    h := array_remove(h, c);
    st := jsonb_set(st, array['hands', s::text], to_jsonb(h));
    st := st || jsonb_build_object('pile', (st->'pile') || to_jsonb(c), 'color', col);
    st := _oc_log(st, jsonb_build_object('s', s, 'a', 'play', 'c', c, 'col', col));
    if cardinality(h) = 1 and not (coalesce((mv->>'uno')::boolean, false) or (st->>'said' is not null and (st->>'said')::int = s)) then
      st := st || jsonb_build_object('uno', s);
    end if;
    if cardinality(h) = 0 then   -- あがり
      st := st || jsonb_build_object('over', true, 'winner', s, 'uno', null, 'why', 'あがり',
              'pts', (select jsonb_agg((select coalesce(sum(_oc_pts(x)), 0) from unnest(_oc_hand(st, i)) x) order by i) from generate_series(0, n - 1) i));
      return st || jsonb_build_object('final', _oc_final(st), 'win', (st->>'win')::int + 1);
    end if;
    if sym = 'S' then return _oc_turn(st, 2); end if;
    if sym = 'R' then
      if n = 2 then return _oc_turn(st, 2); end if;
      return _oc_turn(st || jsonb_build_object('dir', -(st->>'dir')::int), 1);
    end if;
    if sym in ('D', 'F') then
      v := _oc_next(st, 1);
      st := _oc_draw(st, v, case sym when 'D' then 2 else 4 end);
      st := _oc_log(st, jsonb_build_object('s', v, 'a', 'take', 'k', case sym when 'D' then 2 else 4 end));
      return _oc_turn(st, 2);
    end if;
    return _oc_turn(st, 1);
  end if;
  if a = 'draw' then
    if coalesce((st->>'drew')::boolean, false) then raise exception 'もう引きました（引いたカードを出すか、パス）'; end if;
    v := jsonb_array_length(st->'hands'->s);
    st := _oc_draw(st, s, 1);
    h := _oc_hand(st, s);
    st := _oc_log(st, jsonb_build_object('s', s, 'a', 'draw'));
    if cardinality(h) = v then return _oc_turn(st, 1); end if;      -- 山札も捨て札もない
    c := h[cardinality(h)];
    if _oc_ok(st, h, c) then return st || jsonb_build_object('drew', true, 'drawn', c); end if;
    return _oc_turn(st, 1);
  end if;
  if a = 'pass' then
    if not coalesce((st->>'drew')::boolean, false) then raise exception 'パスは、カードを引いたあとだけです'; end if;
    return _oc_turn(_oc_log(st, jsonb_build_object('s', s, 'a', 'pass')), 1);
  end if;
  raise exception 'その動きはできません';
end $$;

-- 順位：あがった人、残りは手札の点数が少ない順（同じなら席の順）。v は「手札の点数のマイナス」
create or replace function public._oc_final(st jsonb) returns jsonb
language plpgsql immutable as $$
declare n int := (st->>'n')::int; pts int[]; w int := (st->>'winner')::int;
begin
  pts := array(select (select coalesce(sum(_oc_pts(x)), 0) from unnest(_oc_hand(st, i)) x) from generate_series(0, n - 1) i order by i);
  return jsonb_build_object('rank', (select jsonb_agg(i order by (i = w) desc nulls last, pts[i + 1], i) from generate_series(0, n - 1) i),
                            'v', (select jsonb_agg(-pts[i + 1] order by i) from generate_series(0, n - 1) i), 'scale', 100, 'ref', 'best');
end $$;

create or replace function public._oc_pending(st jsonb) returns int[]
language sql immutable as $$ select case when coalesce((st->>'over')::boolean, false) then '{}'::int[] else array[(st->>'turn')::int] end $$;

-- コンピューター
create or replace function public._oc_cpu(st jsonb, s int) returns jsonb
language plpgsql immutable as $$
declare h int[] := _oc_hand(st, s); ok int[]; c int; col int; nxt int; nh int;
begin
  if st->>'uno' is not null and (st->>'uno')::int <> s then return '{"a":"catch"}'; end if;
  ok := _oc_legal(st, s);
  if cardinality(ok) = 0 then
    return case when coalesce((st->>'drew')::boolean, false) then '{"a":"pass"}' else '{"a":"draw"}' end::jsonb;
  end if;
  nxt := _oc_next(st, 1); nh := jsonb_array_length(st->'hands'->nxt);
  -- 次の人の手札が少ないときは攻める（ドロー2・スキップ・リバース・ドロー4）。ふだんはワイルドを残し、多い色・大きい数字から
  select x into c from unnest(ok) x
   order by case when nh <= 2 and _oc_sym(x) in ('D', 'F', 'S', 'R') then 0 else 1 end,
            (x >= 100),
            (select count(*) from unnest(h) y where _oc_col(y) = _oc_col(x)) desc,
            _oc_pts(x) desc, x
   limit 1;
  col := coalesce((select _oc_col(y) from unnest(array_remove(h, c)) y where y < 100 group by _oc_col(y) order by count(*) desc, _oc_col(y) limit 1),
                  floor(random() * 4)::int);
  return jsonb_build_object('a', 'play', 'c', c, 'col', col, 'uno', true);
end $$;

-- 見えるもの（自分の手札だけ。終わったら全員の手札）
create or replace function public._oc_view(st jsonb, me int) returns jsonb
language plpgsql immutable as $$
declare n int := (st->>'n')::int; over boolean := coalesce((st->>'over')::boolean, false); my boolean := me is not null and not over and (st->>'turn')::int = me;
begin
  return jsonb_build_object('n', n, 'turn', (st->>'turn')::int, 'dir', (st->>'dir')::int, 'color', (st->>'color')::int,
    'top', _oc_top(st), 'pile_n', jsonb_array_length(st->'pile'), 'deck_n', jsonb_array_length(st->'deck'),
    'counts', (select jsonb_agg(jsonb_array_length(st->'hands'->i) order by i) from generate_series(0, n - 1) i),
    'hand', case when me is null then null else (select coalesce(jsonb_agg(x order by _oc_col(x) < 0, _oc_col(x), _oc_sym(x), x), '[]'::jsonb) from unnest(_oc_hand(st, me)) x) end,
    'hands', case when over then st->'hands' else null end,
    'drew', my and coalesce((st->>'drew')::boolean, false), 'drawn', case when my then st->'drawn' else null end,
    'legal', case when my then to_jsonb(_oc_legal(st, me)) else '[]'::jsonb end,
    'uno', st->'uno', 'said', st->'said', 'log', st->'log', 'over', over, 'winner', st->'winner', 'pts', st->'pts', 'final', st->'final');
end $$;

-- ---------- 麻雀（日本のリーチ麻雀・4人。赤ドラ3枚・喰いタンあり・頭ハネ・東風戦／半荘戦） ----------
--   牌：0〜135（種類 = id / 4）。種類 0〜8 萬子 1〜9・9〜17 筒子・18〜26 索子・27 東 28 南 29 西 30 北・31 白 32 發 33 中
--   赤5：16（5萬）・52（5筒）・88（5索）。配列の数え方（c）は 34 個で、c[種類 + 1] がその牌の枚数
create or replace function public._mj_ids(j jsonb) returns int[]
language sql immutable as $$ select coalesce(array(select jsonb_array_elements_text(j)::int), '{}') $$;

create or replace function public._mj_cnt(ids int[]) returns int[]
language plpgsql immutable as $$
declare c int[] := array_fill(0, array[34]); x int;
begin
  foreach x in array coalesce(ids, '{}') loop c[x / 4 + 1] := c[x / 4 + 1] + 1; end loop;
  return c;
end $$;

-- 么九牌（1・9・字牌）
create or replace function public._mj_yao(k int) returns boolean
language sql immutable as $$ select k >= 27 or k % 9 in (0, 8) $$;

-- 国士無双の形
create or replace function public._mj_kokushi(c int[]) returns boolean
language sql immutable as $$
  select bool_and(c[k + 1] >= 1) and sum(c[k + 1]) = 14 from unnest(array[0, 8, 9, 17, 18, 26, 27, 28, 29, 30, 31, 32, 33]) k $$;

-- 雀頭をのぞいた残りが、全部面子に分けられるか
create or replace function public._mj_sets_ok(c int[]) returns boolean
language plpgsql immutable as $$
declare b int; i int; n int;
begin
  for b in 0..2 loop
    for i in 0..8 loop
      n := c[b * 9 + i + 1];
      if n < 0 then return false; end if;
      n := n % 3;
      if n > 0 then
        if i > 6 then return false; end if;
        c[b * 9 + i + 2] := c[b * 9 + i + 2] - n;
        c[b * 9 + i + 3] := c[b * 9 + i + 3] - n;
      end if;
    end loop;
  end loop;
  for i in 28..34 loop if c[i] % 3 <> 0 then return false; end if; end loop;
  return true;
end $$;

-- あがりの形か（nm：鳴き・カンの数）
create or replace function public._mj_agari(c int[], nm int) returns boolean
language plpgsql immutable as $$
declare k int; d int[];
begin
  if nm = 0 then
    if (select count(*) from unnest(c) x where x = 2) = 7 then return true; end if;
    if _mj_kokushi(c) then return true; end if;
  end if;
  for k in 1..34 loop
    if c[k] >= 2 then
      d := c; d[k] := d[k] - 2;
      if _mj_sets_ok(d) then return true; end if;
    end if;
  end loop;
  return false;
end $$;

-- 待ち（あと1枚であがれる牌の種類）。自分の手で4枚とも使っている牌は待ちにならない
create or replace function public._mj_waits(hand int[], nm int) returns int[]
language plpgsql immutable as $$
declare c int[] := _mj_cnt(hand); k int; w int[] := '{}'; near boolean;
begin
  for k in 0..33 loop
    continue when c[k + 1] >= 4;
    if c[k + 1] = 0 then
      near := k < 27 and ((k % 9 >= 1 and c[k] > 0) or (k % 9 >= 2 and c[k - 1] > 0) or (k % 9 <= 7 and c[k + 2] > 0) or (k % 9 <= 6 and c[k + 3] > 0));
      continue when not near and not (nm = 0 and _mj_yao(k));
    end if;
    c[k + 1] := c[k + 1] + 1;
    if _mj_agari(c, nm) then w := w || k; end if;
    c[k + 1] := c[k + 1] - 1;
  end loop;
  return w;
end $$;

-- シャンテン数：1つの色（または字牌）の中で、面子 m・塔子 t・雀頭 p の組み合わせを全部さがす
--   r[p * 5 + m + 1] = その m・p のときの塔子の最大（作れないなら -1）。hon = true は字牌（順子・両面・嵌張なし）
create or replace function public._mj_sh_part(c int[], i int, m int, t int, p int, r int[], hon boolean) returns int[]
language plpgsql immutable as $$
declare L int := cardinality(c);
begin
  while i <= L and c[i] = 0 loop i := i + 1; end loop;
  if i > L then
    if m <= 4 and r[p * 5 + m + 1] < least(t, 4) then r[p * 5 + m + 1] := least(t, 4); end if;
    return r;
  end if;
  if not hon and i <= L - 2 and c[i + 1] > 0 and c[i + 2] > 0 then
    c[i] := c[i] - 1; c[i + 1] := c[i + 1] - 1; c[i + 2] := c[i + 2] - 1;
    r := _mj_sh_part(c, i, m + 1, t, p, r, hon);
    c[i] := c[i] + 1; c[i + 1] := c[i + 1] + 1; c[i + 2] := c[i + 2] + 1;
  end if;
  if c[i] >= 3 then c[i] := c[i] - 3; r := _mj_sh_part(c, i, m + 1, t, p, r, hon); c[i] := c[i] + 3; end if;
  if c[i] >= 2 and p = 0 then c[i] := c[i] - 2; r := _mj_sh_part(c, i, m, t, 1, r, hon); c[i] := c[i] + 2; end if;
  if c[i] >= 2 then c[i] := c[i] - 2; r := _mj_sh_part(c, i, m, t + 1, p, r, hon); c[i] := c[i] + 2; end if;
  if not hon and i <= L - 1 and c[i + 1] > 0 then
    c[i] := c[i] - 1; c[i + 1] := c[i + 1] - 1; r := _mj_sh_part(c, i, m, t + 1, p, r, hon); c[i] := c[i] + 1; c[i + 1] := c[i + 1] + 1;
  end if;
  if not hon and i <= L - 2 and c[i + 2] > 0 then
    c[i] := c[i] - 1; c[i + 2] := c[i + 2] - 1; r := _mj_sh_part(c, i, m, t + 1, p, r, hon); c[i] := c[i] + 1; c[i + 2] := c[i + 2] + 1;
  end if;
  c[i] := 0;   -- 残りは使わない
  return _mj_sh_part(c, i + 1, m, t, p, r, hon);
end $$;

-- 結果の覚え書き（同じ形を何度も数えないように）
create table if not exists public.mj_cache (k bigint primary key, v int[] not null);
alter table public.mj_cache enable row level security;
revoke all on public.mj_cache from anon, authenticated;

create or replace function public._mj_part(c int[], hon boolean) returns int[]
language plpgsql volatile set search_path = public as $$
declare key bigint := case when hon then 1 else 2 end; x int; r int[];
begin
  foreach x in array c loop key := key * 5 + x; end loop;
  select v into r from mj_cache where k = key;
  if r is null then
    r := _mj_sh_part(c, 1, 0, 0, 0, array_fill(-1, array[10]), hon);
    if pg_try_advisory_xact_lock(7212, key::int) then insert into mj_cache values (key, r) on conflict do nothing; end if;
  end if;
  return r;
end $$;

-- シャンテン数（-1 があがり、0 がテンパイ）。nm：鳴き・カンの数
create or replace function public._mj_shanten(c int[], nm int) returns int
language plpgsql volatile as $$
declare dp int[] := array[0, -1, -1, -1, -1, -1, -1, -1, -1, -1]; nd int[]; r int[]; b int; pp int; pm int; qp int; qm int; v int; best int := 8; s int; t int;
        pairs int; kinds int; yk int; yp int;
begin
  for b in 0..3 loop
    r := case when b < 3 then _mj_part(c[b * 9 + 1:b * 9 + 9], false) else _mj_part(c[28:34], true) end;
    nd := array_fill(-1, array[10]);
    for pp in 0..1 loop for pm in 0..4 loop
      continue when dp[pp * 5 + pm + 1] < 0;
      for qp in 0..1 - pp loop for qm in 0..4 - pm loop
        continue when r[qp * 5 + qm + 1] < 0;
        v := least(dp[pp * 5 + pm + 1] + r[qp * 5 + qm + 1], 4);
        if nd[(pp + qp) * 5 + pm + qm + 1] < v then nd[(pp + qp) * 5 + pm + qm + 1] := v; end if;
      end loop; end loop;
    end loop; end loop;
    dp := nd;
  end loop;
  for pp in 0..1 loop for pm in 0..4 - nm loop
    t := dp[pp * 5 + pm + 1];
    continue when t < 0;
    s := 8 - 2 * (pm + nm) - least(t, 4 - pm - nm) - pp;
    if s < best then best := s; end if;
  end loop; end loop;
  if nm = 0 then
    select count(*) filter (where x >= 2), count(*) filter (where x >= 1) into pairs, kinds from unnest(c) x;
    best := least(best, 6 - pairs + greatest(0, 7 - kinds));
    select count(*) filter (where c[k + 1] >= 1), count(*) filter (where c[k + 1] >= 2) into yk, yp
      from unnest(array[0, 8, 9, 17, 18, 26, 27, 28, 29, 30, 31, 32, 33]) k;
    best := least(best, 13 - yk - case when yp > 0 then 1 else 0 end);
  end if;
  return best;
end $$;

-- 面子への分け方を全部（順子 100 + 種類・刻子 200 + 種類）
create or replace function public._mj_dec_sets(c int[], i int) returns setof int[]
language plpgsql immutable as $$
declare rest int[];
begin
  while i <= 34 and c[i] = 0 loop i := i + 1; end loop;
  if i > 34 then return next '{}'::int[]; return; end if;
  if c[i] >= 3 then
    c[i] := c[i] - 3;
    for rest in select * from _mj_dec_sets(c, i) loop return next (200 + i - 1) || rest; end loop;
    c[i] := c[i] + 3;
  end if;
  if i <= 27 and (i - 1) % 9 <= 6 and c[i + 1] > 0 and c[i + 2] > 0 then
    c[i] := c[i] - 1; c[i + 1] := c[i + 1] - 1; c[i + 2] := c[i + 2] - 1;
    for rest in select * from _mj_dec_sets(c, i) loop return next (100 + i - 1) || rest; end loop;
  end if;
  return;
end $$;

-- 雀頭（300 + 種類）と面子への分け方
create or replace function public._mj_decomp(c int[]) returns setof int[]
language plpgsql immutable as $$
declare k int; d int[]; s int[];
begin
  for k in 1..34 loop
    if c[k] >= 2 then
      d := c; d[k] := d[k] - 2;
      if _mj_sets_ok(d) then
        for s in select * from _mj_dec_sets(d, 1) loop return next (300 + k - 1) || s; end loop;
      end if;
    end if;
  end loop;
end $$;

-- ドラ表示牌の種類 → ドラの種類
create or replace function public._mj_dora_of(k int) returns int
language sql immutable as $$
  select case when k < 27 then (k / 9) * 9 + (k % 9 + 1) % 9 when k <= 30 then 27 + (k - 27 + 1) % 4 else 31 + (k - 31 + 1) % 3 end $$;

create or replace function public._mj_kname(k int) returns text
language sql immutable as $$
  select case when k < 27 then (k % 9 + 1)::text || (array['萬', '筒', '索'])[k / 9 + 1] else (array['東', '南', '西', '北', '白', '發', '中'])[k - 26] end $$;

-- 点数の基本点
create or replace function public._mj_base(han int, fu int, ym int) returns int
language sql immutable as $$
  select case when ym > 0 then 8000 * ym when han >= 13 then 8000 when han >= 11 then 6000 when han >= 8 then 4000
              when han >= 6 then 3000 when han >= 5 then 2000 else least(2000, fu * (2 ^ (han + 2))::int) end $$;

create or replace function public._mj_c100(x int) returns int
language sql immutable as $$ select ((x + 99) / 100) * 100 $$;

-- 役と点数
--   hand：手の中の牌（あがり牌をふくむ 14 − 3×鳴きの数 枚）・melds：鳴き（k：chi / pon / minkan / kakan / ankan、t：牌）
--   x：場のようす（tsumo・dealer・seatw（自風の種類）・roundw（場風の種類）・riichi・dbl・ippatsu・rinshan・chankan・haitei・houtei・tenhou・chiihou・dora（表示牌）・ura（裏ドラ表示牌））
--   役がなければ null
create or replace function public._mj_score(hand int[], melds jsonb, win int, x jsonb) returns jsonb
language plpgsql immutable as $$
declare c int[] := _mj_cnt(hand); allids int[] := hand; ac int[]; nm int := jsonb_array_length(coalesce(melds, '[]'));
        m jsonb; isopen boolean := false; wk int := win / 4; tsumo boolean := coalesce((x->>'tsumo')::boolean, false);
        mseq int[] := '{}'; mtri int[] := '{}'; mtric boolean[] := '{}'; mkan boolean[] := '{}'; kans int := 0;
        d int[]; g int; i int; j int; best jsonb; cur jsonb; ym jsonb; yl jsonb; han int; fu int; dora int := 0; aka int := 0; ura int := 0;
        seqs int[]; tris int[]; tric boolean[]; trik boolean[]; pair int; wait text; slots text[]; sl text; ronopen int;
        yaku jsonb; yh int; base int; yakuhai_k int[]; k int; suits int[]; hon boolean; onlyyao boolean; allhon boolean; allterm boolean;
        green int[] := array[19, 20, 21, 23, 25, 32]; nconc int; npk int; dsum int; wsum int; v int; ymn int; b int; q2 int;
begin
  -- 鳴き
  for m in select * from jsonb_array_elements(coalesce(melds, '[]')) loop
    allids := allids || _mj_ids(m->'t');
    k := (select min(z) from unnest(_mj_ids(m->'t')) z) / 4;
    if m->>'k' = 'chi' then mseq := mseq || k; isopen := true;
    else
      mtri := mtri || k; mtric := mtric || (m->>'k' = 'ankan'); mkan := mkan || (m->>'k' in ('minkan', 'kakan', 'ankan'));
      if m->>'k' <> 'ankan' then isopen := true; end if;
      if m->>'k' in ('minkan', 'kakan', 'ankan') then kans := kans + 1; end if;
    end if;
  end loop;
  ac := _mj_cnt(allids);
  -- ドラ・赤・裏
  for i in select * from unnest(_mj_ids(x->'dora')) loop dora := dora + ac[_mj_dora_of(i / 4) + 1]; end loop;
  if coalesce((x->>'riichi')::boolean, false) then
    for i in select * from unnest(_mj_ids(x->'ura')) loop ura := ura + ac[_mj_dora_of(i / 4) + 1]; end loop;
  end if;
  aka := (select count(*) from unnest(allids) z where z in (16, 52, 88));
  allhon := (select coalesce(sum(ac[q]), 0) from generate_series(1, 27) q) = 0;
  onlyyao := (select bool_and(ac[q + 1] = 0 or _mj_yao(q)) from generate_series(0, 33) q);
  allterm := onlyyao and (select coalesce(sum(ac[q]), 0) from generate_series(28, 34) q) = 0;
  suits := array(select distinct q / 9 from generate_series(0, 26) q where ac[q + 1] > 0);
  hon := (select coalesce(sum(ac[q]), 0) from generate_series(28, 34) q) > 0;

  -- 役満（形に関係ないもの）
  ym := '[]';
  if coalesce((x->>'tenhou')::boolean, false) then ym := ym || '["天和"]'; end if;
  if coalesce((x->>'chiihou')::boolean, false) then ym := ym || '["地和"]'; end if;

  -- 国士無双
  if nm = 0 and _mj_kokushi(c) then
    ym := ym || '["国士無双"]';
    return jsonb_build_object('yakuman', jsonb_array_length(ym), 'yaku', (select jsonb_agg(jsonb_build_array(z, 13)) from jsonb_array_elements_text(ym) z),
                              'han', 13 * jsonb_array_length(ym), 'fu', 0, 'base', _mj_base(0, 0, jsonb_array_length(ym)));
  end if;

  best := null;
  -- 七対子
  if nm = 0 and (select count(*) from unnest(c) z where z = 2) = 7 then
    yl := '[]';
    if allhon then
      yl := ym || '["字一色"]';
    else
      yl := ym;
    end if;
    if jsonb_array_length(yl) > 0 then
      best := jsonb_build_object('yakuman', jsonb_array_length(yl), 'yaku', (select jsonb_agg(jsonb_build_array(z, 13)) from jsonb_array_elements_text(yl) z),
                                 'han', 13 * jsonb_array_length(yl), 'fu', 25, 'base', _mj_base(0, 0, jsonb_array_length(yl)));
    else
      yaku := '[]';
      if coalesce((x->>'riichi')::boolean, false) then yaku := yaku || case when coalesce((x->>'dbl')::boolean, false) then '[["ダブル立直", 2]]' else '[["立直", 1]]' end::jsonb; end if;
      if coalesce((x->>'ippatsu')::boolean, false) then yaku := yaku || '[["一発", 1]]'; end if;
      if tsumo then yaku := yaku || '[["門前清自摸和", 1]]'; end if;
      yaku := yaku || '[["七対子", 2]]';
      if not onlyyao and (select bool_and(ac[q + 1] = 0 or not _mj_yao(q)) from generate_series(0, 33) q) then yaku := yaku || '[["断幺九", 1]]'; end if;
      if onlyyao then yaku := yaku || '[["混老頭", 2]]'; end if;
      if cardinality(suits) = 1 then yaku := yaku || case when hon then '[["混一色", 3]]' else '[["清一色", 6]]' end::jsonb; end if;
      if coalesce((x->>'chankan')::boolean, false) then yaku := yaku || '[["槍槓", 1]]'; end if;
      if coalesce((x->>'haitei')::boolean, false) then yaku := yaku || '[["海底摸月", 1]]'; end if;
      if coalesce((x->>'houtei')::boolean, false) then yaku := yaku || '[["河底撈魚", 1]]'; end if;
      yh := (select sum((z->>1)::int) from jsonb_array_elements(yaku) z);
      if dora > 0 then yaku := yaku || jsonb_build_array(jsonb_build_array('ドラ', dora)); end if;
      if aka > 0 then yaku := yaku || jsonb_build_array(jsonb_build_array('赤ドラ', aka)); end if;
      if ura > 0 then yaku := yaku || jsonb_build_array(jsonb_build_array('裏ドラ', ura)); end if;
      han := yh + dora + aka + ura;
      best := jsonb_build_object('yakuman', 0, 'yaku', yaku, 'han', han, 'fu', 25, 'base', _mj_base(han, 25, 0));
    end if;
  end if;

  -- ふつうの形（4面子1雀頭）
  for d in select * from _mj_decomp(c) loop
    pair := null; seqs := mseq; tris := '{}'; tric := '{}'; trik := '{}';
    foreach g in array d loop
      if g >= 300 then pair := g - 300; elsif g >= 200 then tris := tris || (g - 200); tric := tric || true; trik := trik || false;
      else seqs := seqs || (g - 100); end if;
    end loop;
    -- あがり牌がどこに入ったか（待ちの形）
    slots := '{}';
    if pair = wk then slots := slots || 'T'::text; end if;
    for i in 1..cardinality(tris) loop if tris[i] = wk then slots := slots || ('S' || i); end if; end loop;
    foreach q2 in array array(select distinct z - 100 from unnest(d) z where z between 100 and 199) loop
      if wk between q2 and q2 + 2 then
        slots := slots || case when wk = q2 + 1 then 'K' when (wk = q2 and q2 % 9 = 6) or (wk = q2 + 2 and q2 % 9 = 0) then 'P' else 'R' end;
      end if;
    end loop;
    tris := tris || mtri; tric := tric || mtric; trik := trik || mkan;
    foreach sl in array (select array(select distinct z from unnest(slots) z)) loop
      wait := left(sl, 1);
      ronopen := case when wait = 'S' and not tsumo then substr(sl, 2)::int else 0 end;
      -- 暗刻の数（ロンで完成した刻子は明刻）
      nconc := 0;
      for i in 1..cardinality(tris) loop if tric[i] and i <> ronopen then nconc := nconc + 1; end if; end loop;
      dsum := (select count(*) from unnest(tris) z where z between 31 and 33);
      wsum := (select count(*) from unnest(tris) z where z between 27 and 30);
      -- 役満
      yl := ym;
      if nconc = 4 then yl := yl || '["四暗刻"]'; end if;
      if dsum = 3 then yl := yl || '["大三元"]'; end if;
      if wsum = 4 then yl := yl || '["大四喜"]'; elsif wsum = 3 and pair between 27 and 30 then yl := yl || '["小四喜"]'; end if;
      if allhon then yl := yl || '["字一色"]'; end if;
      if allterm then yl := yl || '["清老頭"]'; end if;
      if (select bool_and(ac[q + 1] = 0 or q = any(green)) from generate_series(0, 33) q) then yl := yl || '["緑一色"]'; end if;
      if kans = 4 then yl := yl || '["四槓子"]'; end if;
      if nm = 0 and cardinality(suits) = 1 and not hon then
        b := suits[1];
        if (select bool_and(c[b * 9 + q + 1] >= (array[3, 1, 1, 1, 1, 1, 1, 1, 3])[q + 1]) from generate_series(0, 8) q) then yl := yl || '["九蓮宝燈"]'; end if;
      end if;
      if jsonb_array_length(yl) > 0 then
        cur := jsonb_build_object('yakuman', jsonb_array_length(yl), 'yaku', (select jsonb_agg(jsonb_build_array(z, 13)) from jsonb_array_elements_text(yl) z),
                                  'han', 13 * jsonb_array_length(yl), 'fu', 0, 'base', _mj_base(0, 0, jsonb_array_length(yl)));
        if best is null or (cur->>'base')::int > (best->>'base')::int then best := cur; end if;
        continue;
      end if;
      -- ふつうの役
      yaku := '[]';
      if coalesce((x->>'riichi')::boolean, false) then yaku := yaku || case when coalesce((x->>'dbl')::boolean, false) then '[["ダブル立直", 2]]' else '[["立直", 1]]' end::jsonb; end if;
      if coalesce((x->>'ippatsu')::boolean, false) then yaku := yaku || '[["一発", 1]]'; end if;
      if tsumo and not isopen then yaku := yaku || '[["門前清自摸和", 1]]'; end if;
      yakuhai_k := array[31, 32, 33, (x->>'seatw')::int, (x->>'roundw')::int];
      if not isopen and cardinality(tris) = 0 and wait = 'R' and not (pair = any(yakuhai_k)) then yaku := yaku || '[["平和", 1]]'; end if;
      if (select bool_and(ac[q + 1] = 0 or not _mj_yao(q)) from generate_series(0, 33) q) then yaku := yaku || '[["断幺九", 1]]'; end if;
      if not isopen then
        npk := (select coalesce(sum(n / 2), 0) from (select count(*) n from unnest(seqs) z group by z) zz);
        if npk >= 2 then yaku := yaku || '[["二盃口", 3]]'; elsif npk = 1 then yaku := yaku || '[["一盃口", 1]]'; end if;
      end if;
      foreach k in array tris loop
        if k = 31 then yaku := yaku || '[["役牌 白", 1]]'; end if;
        if k = 32 then yaku := yaku || '[["役牌 發", 1]]'; end if;
        if k = 33 then yaku := yaku || '[["役牌 中", 1]]'; end if;
        if k = (x->>'seatw')::int then yaku := yaku || jsonb_build_array(jsonb_build_array('自風 ' || _mj_kname(k), 1)); end if;
        if k = (x->>'roundw')::int then yaku := yaku || jsonb_build_array(jsonb_build_array('場風 ' || _mj_kname(k), 1)); end if;
      end loop;
      if coalesce((x->>'rinshan')::boolean, false) then yaku := yaku || '[["嶺上開花", 1]]'; end if;
      if coalesce((x->>'chankan')::boolean, false) then yaku := yaku || '[["槍槓", 1]]'; end if;
      if coalesce((x->>'haitei')::boolean, false) then yaku := yaku || '[["海底摸月", 1]]'; end if;
      if coalesce((x->>'houtei')::boolean, false) then yaku := yaku || '[["河底撈魚", 1]]'; end if;
      if exists (select 1 from generate_series(0, 6) q where q = any(seqs) and q + 9 = any(seqs) and q + 18 = any(seqs)) then
        yaku := yaku || jsonb_build_array(jsonb_build_array('三色同順', case when isopen then 1 else 2 end));
      end if;
      if exists (select 1 from generate_series(0, 2) q where q * 9 = any(seqs) and q * 9 + 3 = any(seqs) and q * 9 + 6 = any(seqs)) then
        yaku := yaku || jsonb_build_array(jsonb_build_array('一気通貫', case when isopen then 1 else 2 end));
      end if;
      if cardinality(seqs) > 0 and _mj_yao(pair) and (select bool_and(z % 9 in (0, 6)) from unnest(seqs) z) and (select coalesce(bool_and(_mj_yao(z)), true) from unnest(tris) z) then
        if hon then yaku := yaku || jsonb_build_array(jsonb_build_array('混全帯幺九', case when isopen then 1 else 2 end));
        else yaku := yaku || jsonb_build_array(jsonb_build_array('純全帯幺九', case when isopen then 2 else 3 end)); end if;
      end if;
      if cardinality(seqs) = 0 then yaku := yaku || '[["対々和", 2]]'; end if;
      if nconc = 3 then yaku := yaku || '[["三暗刻", 2]]'; end if;
      if exists (select 1 from generate_series(0, 8) q where q = any(tris) and q + 9 = any(tris) and q + 18 = any(tris)) then yaku := yaku || '[["三色同刻", 2]]'; end if;
      if kans = 3 then yaku := yaku || '[["三槓子", 2]]'; end if;
      if dsum = 2 and pair between 31 and 33 then yaku := yaku || '[["小三元", 2]]'; end if;
      if onlyyao then yaku := yaku || '[["混老頭", 2]]'; end if;
      if cardinality(suits) = 1 then
        if hon then yaku := yaku || jsonb_build_array(jsonb_build_array('混一色', case when isopen then 2 else 3 end));
        else yaku := yaku || jsonb_build_array(jsonb_build_array('清一色', case when isopen then 5 else 6 end)); end if;
      end if;
      yh := coalesce((select sum((z->>1)::int) from jsonb_array_elements(yaku) z), 0);
      continue when yh = 0;
      -- 符
      if not isopen and cardinality(tris) = 0 and wait = 'R' and not (pair = any(yakuhai_k)) then
        fu := case when tsumo then 20 else 30 end;
      else
        fu := 20;
        if not isopen and not tsumo then fu := fu + 10; end if;
        if tsumo then fu := fu + 2; end if;
        for i in 1..cardinality(tris) loop
          v := case when trik[i] then 8 else 2 end;
          if tric[i] and i <> ronopen then v := v * 2; end if;
          if _mj_yao(tris[i]) then v := v * 2; end if;
          fu := fu + v;
        end loop;
        if pair between 31 and 33 then fu := fu + 2; end if;
        if pair = (x->>'seatw')::int then fu := fu + 2; end if;
        if pair = (x->>'roundw')::int then fu := fu + 2; end if;
        if wait in ('K', 'P', 'T') then fu := fu + 2; end if;
        fu := ((fu + 9) / 10) * 10;
        if isopen and fu = 20 then fu := 30; end if;
      end if;
      if dora > 0 then yaku := yaku || jsonb_build_array(jsonb_build_array('ドラ', dora)); end if;
      if aka > 0 then yaku := yaku || jsonb_build_array(jsonb_build_array('赤ドラ', aka)); end if;
      if ura > 0 then yaku := yaku || jsonb_build_array(jsonb_build_array('裏ドラ', ura)); end if;
      han := yh + dora + aka + ura;
      base := _mj_base(han, fu, 0);
      cur := jsonb_build_object('yakuman', 0, 'yaku', yaku, 'han', han, 'fu', fu, 'base', base);
      if best is null or base > (best->>'base')::int or (base = (best->>'base')::int and (han > (best->>'han')::int or (han = (best->>'han')::int and fu > (best->>'fu')::int))) then
        best := cur;
      end if;
    end loop;
  end loop;
  return best;
end $$;

-- 支払い（親：dealer。ron：放銃者がはらう合計、tsumo_oya・tsumo_ko：ツモのときに親・子がはらう額（本場をのぞく））
create or replace function public._mj_pay(base int, dealer boolean) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ron', case when dealer then _mj_c100(base * 6) else _mj_c100(base * 4) end,
                            'tsumo_oya', case when dealer then 0 else _mj_c100(base * 2) end,
                            'tsumo_ko', case when dealer then _mj_c100(base * 2) else _mj_c100(base) end) $$;

-- 点数のよび名
create or replace function public._mj_label(sc jsonb) returns text
language sql immutable as $$
  select case when (sc->>'yakuman')::int >= 2 then (sc->>'yakuman') || '倍役満' when (sc->>'yakuman')::int = 1 then '役満'
              when (sc->>'han')::int >= 13 then '数え役満' when (sc->>'han')::int >= 11 then '三倍満' when (sc->>'han')::int >= 8 then '倍満'
              when (sc->>'han')::int >= 6 then '跳満' when (sc->>'base')::int >= 2000 then '満貫'
              else (sc->>'fu') || '符' || (sc->>'han') || '翻' end $$;

-- ---------- 麻雀の進行 ----------
--   状態：rules（len：east 東風戦 / south 半荘戦）・round（場：0 東・1 南）・kyoku（局。親の席）・honba・kyotaku（リーチ棒）・scores
--         dead（王牌14枚：0〜3 嶺上牌・4〜8 ドラ表示牌・9〜13 裏ドラ表示牌）・wall（山）・hands・melds・river（捨て牌）
--         riichi（宣言した捨て牌の番号。-1 はなし）・ippatsu・dbl・fur（見のがし振聴）・furr（リーチ後の振聴）・fd（まだ1回も捨てていない）
--         kans・dora_n・rin（使った嶺上牌）・calls（鳴き・カンの回数）・first4・rpend（宣言したばかりのリーチ）・waits（待ち）
--         phase：act（turn の人が打つ）/ call（捨て牌に対してロン・ポン・チー・カン）/ rob（槍槓）/ end（局の結果）/ over
--         pend（鳴ける人とできること）・resp（答え）・aopt（打つ人ができること）・result・ready・timer_at・win・log
create or replace function public._mj_log(st jsonb, e jsonb) returns jsonb
language sql immutable as $$
  select jsonb_set(st, '{log}', coalesce((select jsonb_agg(x order by o) from (
           select x, o from jsonb_array_elements(coalesce(st->'log', '[]'::jsonb) || jsonb_build_array(e)) with ordinality t(x, o)
            order by o desc limit 24) z), '[]'::jsonb)) $$;

create or replace function public._mj_hand(st jsonb, s int) returns int[]
language sql immutable as $$ select _mj_ids(st->'hands'->s) $$;

create or replace function public._mj_set(st jsonb, k text, s int, v jsonb) returns jsonb
language sql immutable as $$ select jsonb_set(st, array[k, s::text], v) $$;

create or replace function public._mj_sorted(a int[]) returns jsonb
language sql immutable as $$ select coalesce(jsonb_agg(x order by x), '[]'::jsonb) from unnest(a) x $$;

create or replace function public._mj_nm(st jsonb, s int) returns int
language sql immutable as $$ select jsonb_array_length(st->'melds'->s) $$;

create or replace function public._mj_open(st jsonb, s int) returns boolean
language sql immutable as $$ select exists (select 1 from jsonb_array_elements(st->'melds'->s) m where m->>'k' <> 'ankan') $$;

create or replace function public._mj_wall_n(st jsonb) returns int
language sql immutable as $$ select jsonb_array_length(st->'wall') $$;

create or replace function public._mj_seatw(st jsonb, s int) returns int
language sql immutable as $$ select 27 + (s - (st->>'kyoku')::int + 4) % 4 $$;

create or replace function public._mj_has(h int[], ks int[]) returns boolean
language sql immutable as $$
  select not exists (select 1 from (select z, count(*) n from unnest(ks) z group by z) need
                      where need.n > (select count(*) from unnest(h) x where x / 4 = need.z)) $$;

-- 鳴いたあと、捨てられる牌が残るか（喰い替えの牌は捨てられない）
create or replace function public._mj_can_after(h int[], ks int[], forbid int[]) returns boolean
language plpgsql immutable as $$
declare c int[] := _mj_cnt(h); k int;
begin
  foreach k in array ks loop c[k + 1] := c[k + 1] - 1; end loop;
  return exists (select 1 from generate_series(0, 33) q where c[q + 1] > 0 and not (q = any(forbid)));
end $$;

-- チーのあとに捨てられない牌（a：順子の始まり − 鳴いた牌。0 は鳴いた牌が下の端、-2 は上の端）
create or replace function public._mj_kuikae_chi(k int, a int) returns int[]
language sql immutable as $$
  select case when a = 0 and k % 9 <= 5 then array[k, k + 3] when a = -2 and k % 9 >= 3 then array[k, k - 3] else array[k] end $$;

-- 鳴くときに使う牌（赤5を使わない／使う）
create or replace function public._mj_variants(h int[], ks int[]) returns jsonb
language plpgsql immutable as $$
declare k int; used int[] := '{}'; res jsonb := '[]'; hasred boolean := false; y0 int;
begin
  foreach k in array ks loop
    select y into y0 from unnest(h) y where y / 4 = k and not (y = any(used)) order by (y in (16, 52, 88)), y limit 1;
    used := used || y0;
  end loop;
  res := res || jsonb_build_array(_mj_sorted(used));
  used := '{}';
  foreach k in array ks loop
    select y into y0 from unnest(h) y where y / 4 = k and not (y = any(used)) order by (y in (16, 52, 88)) desc, y limit 1;
    if y0 in (16, 52, 88) then hasred := true; end if;
    used := used || y0;
  end loop;
  if hasred and _mj_sorted(used) <> res->0 then res := res || jsonb_build_array(_mj_sorted(used)); end if;
  return res;
end $$;

-- 役を数えるときの場のようす
create or replace function public._mj_ctx(st jsonb, s int, tsumo boolean, chankan boolean) returns jsonb
language plpgsql immutable as $$
declare dn int := (st->>'dora_n')::int; ri boolean := (st->'riichi'->>s)::int >= 0; wn int := _mj_wall_n(st);
        first boolean := (st->'fd'->>s)::boolean and (st->>'calls')::int = 0; rin boolean := coalesce((st->>'rinshan')::boolean, false);
begin
  return jsonb_build_object('tsumo', tsumo, 'seatw', _mj_seatw(st, s), 'roundw', 27 + (st->>'round')::int,
    'riichi', ri, 'dbl', ri and (st->'dbl'->>s)::boolean, 'ippatsu', ri and (st->'ippatsu'->>s)::boolean,
    'rinshan', tsumo and rin, 'chankan', chankan, 'haitei', tsumo and not rin and wn = 0, 'houtei', not tsumo and not chankan and wn = 0,
    'tenhou', tsumo and first and s = (st->>'kyoku')::int, 'chiihou', tsumo and first and s <> (st->>'kyoku')::int,
    'dora', (select jsonb_agg(st->'dead'->(4 + q)) from generate_series(0, dn - 1) q),
    'ura', case when ri then (select jsonb_agg(st->'dead'->(9 + q)) from generate_series(0, dn - 1) q) else '[]'::jsonb end);
end $$;

-- あがれるなら点数（ロンは t を足す）
create or replace function public._mj_try(st jsonb, s int, t int, tsumo boolean, chankan boolean) returns jsonb
language plpgsql immutable as $$
declare h int[] := _mj_hand(st, s);
begin
  if not tsumo then h := h || t; end if;
  if not _mj_agari(_mj_cnt(h), _mj_nm(st, s)) then return null; end if;
  return _mj_score(h, st->'melds'->s, t, _mj_ctx(st, s, tsumo, chankan));
end $$;

-- 振聴（ロンできない）
create or replace function public._mj_furiten(st jsonb, p int) returns boolean
language sql immutable as $$
  select coalesce((st->'fur'->>p)::boolean, false) or coalesce((st->'furr'->>p)::boolean, false)
      or exists (select 1 from jsonb_array_elements(st->'river'->p) r where ((r->>'t')::int / 4) = any(_mj_ids(st->'waits'->p))) $$;

-- 打つ人ができること（ツモ・捨てられる牌・リーチできる牌・カン・九種九牌）
create or replace function public._mj_actopts(st jsonb) returns jsonb
language plpgsql volatile as $$
declare s int := (st->>'turn')::int; h int[] := _mj_hand(st, s); c int[] := _mj_cnt(h); nm int := _mj_nm(st, s);
        ri boolean := (st->'riichi'->>s)::int >= 0; dr int := (st->>'drawn')::int; o jsonb := '{}'; k int; rl int[] := '{}';
        kans int[] := '{}'; wn int := _mj_wall_n(st); tk int := (select sum(x::int) from jsonb_array_elements_text(st->'kans') x);
        disc int[]; kk int[] := _mj_ids(st->'kuikae'); m jsonb; w0 int[]; h2 int[]; c2 int[];
begin
  if dr is not null and _mj_agari(c, nm) and _mj_try(st, s, dr, true, false) is not null then o := o || '{"tsumo": true}'; end if;
  if ri then disc := array[dr];
  else disc := coalesce(array(select x from unnest(h) x where not ((x / 4) = any(kk)) order by x), '{}'); end if;
  o := o || jsonb_build_object('discard', to_jsonb(disc));
  if dr is not null and not ri and not _mj_open(st, s) and (st->'scores'->>s)::int >= 1000 and wn >= 4 and _mj_shanten(c, nm) <= 0 then
    for k in select distinct x / 4 from unnest(h) x loop
      c2 := c; c2[k + 1] := c2[k + 1] - 1;
      if _mj_shanten(c2, nm) = 0 and cardinality(_mj_waits(array_remove(h, (select x from unnest(h) x where x / 4 = k limit 1)), nm)) > 0 then
        rl := rl || array(select x from unnest(h) x where x / 4 = k order by x);
      end if;
    end loop;
    if cardinality(rl) > 0 then o := o || jsonb_build_object('riichi', to_jsonb(rl)); end if;
  end if;
  if dr is not null and wn > 0 and tk < 4 then
    for k in 0..33 loop
      if c[k + 1] = 4 then
        if not ri then kans := kans || k;
        elsif k = dr / 4 then   -- リーチ後は、待ちが変わらないときだけ
          h2 := array(select x from unnest(h) x where x / 4 <> k);
          w0 := _mj_ids(st->'waits'->s);
          if cardinality(w0) > 0 and _mj_waits(h2, nm + 1) = w0 then kans := kans || k; end if;
        end if;
      end if;
    end loop;
    if not ri then
      for m in select * from jsonb_array_elements(st->'melds'->s) loop
        if m->>'k' = 'pon' and c[(m->'t'->>0)::int / 4 + 1] >= 1 then kans := kans || ((m->'t'->>0)::int / 4); end if;
      end loop;
    end if;
    if cardinality(kans) > 0 then o := o || jsonb_build_object('kan', to_jsonb(kans)); end if;
  end if;
  if dr is not null and (st->'fd'->>s)::boolean and (st->>'calls')::int = 0
     and (select count(*) from generate_series(0, 33) q where _mj_yao(q) and c[q + 1] > 0) >= 9 then o := o || '{"kyuushu": true}'; end if;
  return st || jsonb_build_object('aopt', o);
end $$;

-- 牌を引く（rin：嶺上牌。そのぶん山の最後が1枚へる）
create or replace function public._mj_draw(st jsonb, s int, rin boolean) returns jsonb
language plpgsql volatile as $$
declare t int; w int[] := _mj_ids(st->'wall'); r int := (st->>'rin')::int;
begin
  if rin then
    t := (st->'dead'->>r)::int;
    st := st || jsonb_build_object('rin', r + 1, 'wall', to_jsonb(w[1:cardinality(w) - 1]), 'dead', (st->'dead') || to_jsonb(w[cardinality(w)]));
  else
    t := w[1];
    st := st || jsonb_build_object('wall', to_jsonb(coalesce(w[2:], '{}')));
  end if;
  st := _mj_set(st, 'hands', s, _mj_sorted(_mj_hand(st, s) || t));
  st := st || jsonb_build_object('phase', 'act', 'turn', s, 'drawn', t, 'rinshan', rin, 'kuikae', '[]'::jsonb,
                                 'pend', '[]'::jsonb, 'resp', '{}'::jsonb, 'timer_at', null, 'cwok', null, 'win', (st->>'win')::int + 1);
  return _mj_actopts(st);
end $$;

-- 配る
create or replace function public._mj_deal(st jsonb) returns jsonb
language plpgsql volatile as $$
declare w int[]; d int := (st->>'kyoku')::int; hs jsonb := '[]'; i int;
begin
  w := array(select g from generate_series(0, 135) g order by random());
  for i in 0..3 loop hs := hs || jsonb_build_array(_mj_sorted(w[15 + i * 13:27 + i * 13])); end loop;
  st := st || jsonb_build_object('dead', to_jsonb(w[1:14]), 'wall', to_jsonb(w[67:136]), 'hands', hs,
    'melds', '[[],[],[],[]]'::jsonb, 'river', '[[],[],[],[]]'::jsonb, 'riichi', '[-1,-1,-1,-1]'::jsonb,
    'ippatsu', '[false,false,false,false]'::jsonb, 'dbl', '[false,false,false,false]'::jsonb,
    'fur', '[false,false,false,false]'::jsonb, 'furr', '[false,false,false,false]'::jsonb, 'fd', '[true,true,true,true]'::jsonb,
    'kans', '[0,0,0,0]'::jsonb, 'dora_n', 1, 'rin', 0, 'calls', 0, 'first4', '[]'::jsonb, 'rpend', null,
    'last', null, 'result', null, 'ready', null, 'timer_at', null, 'renchan', null, 'aopt', null);
  st := jsonb_set(st, '{waits}', (select jsonb_agg(case when q = d then '[]'::jsonb else to_jsonb(_mj_waits(_mj_ids(st->'hands'->q), 0)) end order by q)
                                    from generate_series(0, 3) q));
  st := _mj_log(st, jsonb_build_object('a', 'start', 'round', (st->>'round')::int, 'kyoku', d, 'honba', (st->>'honba')::int));
  return _mj_draw(st, d, false);
end $$;

create or replace function public._mj_init(opts jsonb) returns jsonb
language plpgsql volatile as $$
begin
  return _mj_deal(jsonb_build_object('rules', jsonb_build_object('len', case when opts->>'len' = 'south' then 'south' else 'east' end),
    'round', 0, 'kyoku', 0, 'honba', 0, 'kyotaku', 0, 'scores', '[25000,25000,25000,25000]'::jsonb, 'win', 0, 'log', '[]'::jsonb, 'over', false));
end $$;

-- 順位（点の多い順。同じ点なら起家に近い順）
create or replace function public._mj_final(st jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('rank', (select jsonb_agg(q order by (st->'scores'->>q)::int desc, q) from generate_series(0, 3) q),
                            'v', st->'scores', 'scale', 25000, 'ref', 'avg') $$;

-- 局の終わり（点数を動かして結果を出す）
create or replace function public._mj_end(st jsonb, res jsonb, ren boolean) returns jsonb
language plpgsql volatile as $$
declare dl int[] := _mj_ids(res->'delta'); p int;
begin
  for p in 0..3 loop st := _mj_set(st, 'scores', p, to_jsonb((st->'scores'->>p)::int + coalesce(dl[p + 1], 0))); end loop;
  return st || jsonb_build_object('phase', 'end', 'result', res || jsonb_build_object('scores', st->'scores', 'honba', st->'honba'), 'renchan', ren,
    'ready', '[false,false,false,false]'::jsonb, 'timer_at', coalesce((st->>'now')::bigint, 0) + 25000,
    'pend', '[]'::jsonb, 'resp', '{}'::jsonb, 'aopt', null, 'drawn', null, 'win', (st->>'win')::int + 1);
end $$;

create or replace function public._mj_abort(st jsonb, why text) returns jsonb
language sql volatile as $$
  select _mj_end(_mj_log(st, jsonb_build_object('a', 'abort', 'why', why)), jsonb_build_object('kind', 'abort', 'reason', why, 'delta', '[0,0,0,0]'::jsonb), true) $$;

-- 流局（山がなくなった）：テンパイの人に、ノーテンの人から合わせて3000点
create or replace function public._mj_ryukyoku(st jsonb) returns jsonb
language plpgsql volatile as $$
declare tp boolean[] := '{}'; n int := 0; p int; delta int[] := array[0, 0, 0, 0]; hs jsonb := '{}';
begin
  for p in 0..3 loop
    tp := tp || (jsonb_array_length(st->'waits'->p) > 0);
    if tp[p + 1] then n := n + 1; hs := hs || jsonb_build_object(p::text, st->'hands'->p); end if;
  end loop;
  if n between 1 and 3 then
    for p in 0..3 loop delta[p + 1] := case when tp[p + 1] then 3000 / n else -3000 / (4 - n) end; end loop;
  end if;
  st := _mj_log(st, '{"a": "ryukyoku"}');
  return _mj_end(st, jsonb_build_object('kind', 'ryukyoku', 'reason', '流局', 'tenpai', to_jsonb(tp), 'hands', hs, 'delta', to_jsonb(delta)),
                 tp[(st->>'kyoku')::int + 1]);
end $$;

-- あがり
create or replace function public._mj_win(st jsonb, w int, frm int, t int, tsumo boolean, chankan boolean) returns jsonb
language plpgsql volatile as $$
declare sc jsonb := _mj_try(st, w, t, tsumo, chankan); d int := (st->>'kyoku')::int; hb int := (st->>'honba')::int; pay jsonb;
        delta int[] := array[0, 0, 0, 0]; p int; amt int; h int[] := _mj_hand(st, w); dn int := (st->>'dora_n')::int; tot int := 0;
begin
  if sc is null then raise exception 'あがれません（役がありません）'; end if;
  pay := _mj_pay((sc->>'base')::int, w = d);
  if tsumo then
    for p in 0..3 loop
      continue when p = w;
      amt := case when w = d or p <> d then (pay->>'tsumo_ko')::int else (pay->>'tsumo_oya')::int end + 100 * hb;
      delta[p + 1] := -amt; tot := tot + amt;
    end loop;
  else
    amt := (pay->>'ron')::int + 300 * hb;
    delta[frm + 1] := -amt; tot := amt;
    h := h || t;
  end if;
  delta[w + 1] := tot + 1000 * (st->>'kyotaku')::int;
  st := st || jsonb_build_object('kyotaku', 0, 'rpend', null);
  st := _mj_log(st, jsonb_build_object('a', case when tsumo then 'tsumo' else 'ron' end, 's', w, 'from', frm, 't', t));
  return _mj_end(st, jsonb_build_object('kind', case when tsumo then 'tsumo' else 'ron' end,
      'win', jsonb_build_object('s', w, 'from', frm, 't', t, 'hand', _mj_sorted(h), 'melds', st->'melds'->w,
         'yaku', sc->'yaku', 'han', sc->'han', 'fu', sc->'fu', 'yakuman', sc->'yakuman', 'label', _mj_label(sc),
         'points', case when not tsumo then (pay->>'ron') || '点'
                        when w = d then (pay->>'tsumo_ko') || '点オール'
                        else (pay->>'tsumo_ko') || '・' || (pay->>'tsumo_oya') || '点' end,
         'dora', (select jsonb_agg(st->'dead'->(4 + q)) from generate_series(0, dn - 1) q),
         'ura', case when (st->'riichi'->>w)::int >= 0 then (select jsonb_agg(st->'dead'->(9 + q)) from generate_series(0, dn - 1) q) else '[]'::jsonb end),
      'delta', to_jsonb(delta)), w = d);
end $$;

-- 終局（残ったリーチ棒は1位に）
create or replace function public._mj_over(st jsonb, why text) returns jsonb
language plpgsql volatile as $$
declare top int := ((_mj_final(st))->'rank'->>0)::int;
begin
  if (st->>'kyotaku')::int > 0 then
    st := _mj_set(st, 'scores', top, to_jsonb((st->'scores'->>top)::int + 1000 * (st->>'kyotaku')::int));
    st := st || jsonb_build_object('kyotaku', 0);
  end if;
  st := st || jsonb_build_object('phase', 'over', 'over', true, 'why', why, 'timer_at', null, 'win', (st->>'win')::int + 1);
  return st || jsonb_build_object('final', _mj_final(st));
end $$;

-- 次の局
create or replace function public._mj_next_hand(st jsonb) returns jsonb
language plpgsql volatile as $$
declare ren boolean := coalesce((st->>'renchan')::boolean, false); kind text := st->'result'->>'kind';
        rd int := (st->>'round')::int; ky int := (st->>'kyoku')::int; lastr int := case when st->'rules'->>'len' = 'south' then 1 else 0 end;
begin
  if exists (select 1 from jsonb_array_elements_text(st->'scores') x where x::int < 0) then return _mj_over(st, '飛び（点数がマイナスになった人がいる）'); end if;
  if rd = lastr and ky = 3 then
    if not ren then return _mj_over(st, '終局'); end if;
    if ((_mj_final(st))->'rank'->>0)::int = ky then return _mj_over(st, '終局（オーラスで親がトップ）'); end if;
  end if;
  st := st || jsonb_build_object('honba', case when kind in ('ryukyoku', 'abort') or ren then (st->>'honba')::int + 1 else 0 end);
  if not ren then
    ky := ky + 1;
    if ky = 4 then ky := 0; rd := rd + 1; end if;
  end if;
  return _mj_deal(st || jsonb_build_object('round', rd, 'kyoku', ky));
end $$;

-- 次の人が引く（その前に、途中流局・流局を見る）
create or replace function public._mj_after(st jsonb) returns jsonb
language plpgsql volatile as $$
declare f int[] := _mj_ids(st->'first4');
begin
  if cardinality(f) = 4 and (st->>'calls')::int = 0 and f[1] between 27 and 30 and f[2] = f[1] and f[3] = f[1] and f[4] = f[1] then
    return _mj_abort(st, '四風連打');
  end if;
  if (select sum(x::int) from jsonb_array_elements_text(st->'kans') x) >= 4 and (select max(x::int) from jsonb_array_elements_text(st->'kans') x) < 4 then
    return _mj_abort(st, '四槓散了');
  end if;
  if _mj_wall_n(st) = 0 then return _mj_ryukyoku(st); end if;
  return _mj_draw(st, ((st->'last'->>'s')::int + 1) % 4, false);
end $$;

-- 鳴く（ポン・チー・大明槓）
create or replace function public._mj_call(st jsonb, p int, r jsonb) returns jsonb
language plpgsql volatile as $$
declare s int := (st->'last'->>'s')::int; t int := (st->'last'->>'t')::int; k int := t / 4; h int[] := _mj_hand(st, p); use int[];
        kind text := r->>'a'; n int; kk int[]; a int;
begin
  if kind = 'kan' then use := array(select x from unnest(h) x where x / 4 = k);
  else use := _mj_ids(r->'t'); end if;
  h := array(select x from unnest(h) x where not (x = any(use)));
  st := _mj_set(st, 'hands', p, _mj_sorted(h));
  st := _mj_set(st, 'melds', p, (st->'melds'->p) || jsonb_build_object('k', case kind when 'kan' then 'minkan' else kind end,
                                   't', _mj_sorted(use || t), 'from', s, 'c', t));
  n := jsonb_array_length(st->'river'->s) - 1;
  st := jsonb_set(st, array['river', s::text, n::text, 'x'], 'true');
  st := st || jsonb_build_object('calls', (st->>'calls')::int + 1, 'ippatsu', '[false,false,false,false]'::jsonb, 'fd', '[false,false,false,false]'::jsonb);
  st := _mj_log(st, jsonb_build_object('a', kind, 's', p, 't', t, 'from', s));
  if kind = 'kan' then
    st := _mj_set(st, 'kans', p, to_jsonb((st->'kans'->>p)::int + 1));
    st := st || jsonb_build_object('dora_n', (st->>'dora_n')::int + 1);
    return _mj_draw(st, p, true);
  end if;
  if kind = 'pon' then kk := array[k];
  else
    a := least((select min(x / 4) from unnest(use) x), k) - k;
    kk := _mj_kuikae_chi(k, a);
  end if;
  st := st || jsonb_build_object('phase', 'act', 'turn', p, 'drawn', null, 'rinshan', false, 'kuikae', to_jsonb(kk),
                                 'pend', '[]'::jsonb, 'resp', '{}'::jsonb, 'timer_at', null, 'cwok', null, 'win', (st->>'win')::int + 1);
  return _mj_actopts(st);
end $$;

-- 捨て牌への答えがそろったら決める（ロンは頭ハネ → ポン・カン → チー → 次の人）
create or replace function public._mj_resolve(st jsonb) returns jsonb
language plpgsql volatile as $$
declare s int := (st->'last'->>'s')::int; t int := (st->'last'->>'t')::int; k int := t / 4; p int; r jsonb; rob boolean := st->>'phase' = 'rob';
begin
  for p in select (s + q) % 4 from generate_series(1, 3) q loop
    if st->'resp'->(p::text)->>'a' = 'ron' then return _mj_win(st, p, s, t, false, rob); end if;
  end loop;
  for p in select (s + q) % 4 from generate_series(1, 3) q loop   -- あがれる牌を見のがした人は振聴
    if k = any(_mj_ids(st->'waits'->p)) then
      st := _mj_set(st, 'fur', p, 'true');
      if (st->'riichi'->>p)::int >= 0 then st := _mj_set(st, 'furr', p, 'true'); end if;
    end if;
  end loop;
  if rob then   -- 槍槓がなかったので、加槓が決まる
    st := _mj_set(st, 'kans', s, to_jsonb((st->'kans'->>s)::int + 1));
    st := st || jsonb_build_object('dora_n', (st->>'dora_n')::int + 1);
    return _mj_draw(st, s, true);
  end if;
  if st->>'rpend' is not null then   -- リーチが通った
    p := (st->>'rpend')::int;
    st := _mj_set(st, 'scores', p, to_jsonb((st->'scores'->>p)::int - 1000));
    st := st || jsonb_build_object('kyotaku', (st->>'kyotaku')::int + 1, 'rpend', null);
    if (select count(*) from jsonb_array_elements_text(st->'riichi') x where x::int >= 0) = 4 then return _mj_abort(st, '四家立直'); end if;
  end if;
  for p in select (s + q) % 4 from generate_series(1, 3) q loop
    r := st->'resp'->(p::text);
    if r->>'a' in ('pon', 'kan') then return _mj_call(st, p, r); end if;
  end loop;
  for p in select (s + q) % 4 from generate_series(1, 3) q loop
    r := st->'resp'->(p::text);
    if r->>'a' = 'chi' then return _mj_call(st, p, r); end if;
  end loop;
  return _mj_after(st);
end $$;

-- 捨てる（rii：リーチ宣言）
create or replace function public._mj_discard(st jsonb, s int, t int, rii boolean) returns jsonb
language plpgsql volatile as $$
declare h int[]; k int := t / 4; p int; o jsonb; pend jsonb := '[]'; hp int[]; cn int; wn int; fd0 boolean := (st->'fd'->>s)::boolean;
        ch jsonb; a int; ks int[];
begin
  h := array_remove(_mj_hand(st, s), t);
  st := _mj_set(st, 'hands', s, _mj_sorted(h));
  st := _mj_set(st, 'river', s, (st->'river'->s) || jsonb_build_object('t', t, 'r', rii, 'g', t = coalesce((st->>'drawn')::int, -1), 'x', false));
  if rii then
    st := _mj_set(st, 'riichi', s, to_jsonb(jsonb_array_length(st->'river'->s) - 1));
    st := _mj_set(st, 'dbl', s, to_jsonb(fd0 and (st->>'calls')::int = 0));
    st := _mj_set(st, 'ippatsu', s, 'true');
    st := st || jsonb_build_object('rpend', s);
  else
    st := _mj_set(st, 'ippatsu', s, 'false');
  end if;
  if fd0 and (st->>'calls')::int = 0 then st := st || jsonb_build_object('first4', (st->'first4') || to_jsonb(k)); end if;
  st := _mj_set(st, 'fd', s, 'false');
  st := _mj_set(st, 'fur', s, 'false');
  st := _mj_set(st, 'waits', s, to_jsonb(_mj_waits(h, _mj_nm(st, s))));
  st := st || jsonb_build_object('last', jsonb_build_object('s', s, 't', t), 'drawn', null, 'kuikae', '[]'::jsonb, 'rinshan', false, 'aopt', null);
  st := _mj_log(st, jsonb_build_object('a', case when rii then 'riichi' else 'discard' end, 's', s, 't', t));
  wn := _mj_wall_n(st);
  for p in select (s + q) % 4 from generate_series(1, 3) q loop
    o := '{}';
    if k = any(_mj_ids(st->'waits'->p)) and not _mj_furiten(st, p) and _mj_try(st, p, t, false, false) is not null then o := o || '{"ron": true}'; end if;
    if wn > 0 and (st->'riichi'->>p)::int < 0 then
      hp := _mj_hand(st, p);
      cn := (select count(*) from unnest(hp) x where x / 4 = k);
      if cn >= 2 and _mj_can_after(hp, array[k, k], array[k]) then o := o || jsonb_build_object('pon', _mj_variants(hp, array[k, k])); end if;
      if cn = 3 and (select sum(x::int) from jsonb_array_elements_text(st->'kans') x) < 4 then o := o || '{"kan": true}'; end if;
      if p = (s + 1) % 4 and k < 27 then
        ch := '[]';
        foreach a in array array[-2, -1, 0] loop
          if (k % 9) + a >= 0 and (k % 9) + a + 2 <= 8 then
            ks := array(select k + a + z from generate_series(0, 2) z where a + z <> 0);
            if _mj_has(hp, ks) and _mj_can_after(hp, ks, _mj_kuikae_chi(k, a)) then ch := ch || _mj_variants(hp, ks); end if;
          end if;
        end loop;
        if jsonb_array_length(ch) > 0 then o := o || jsonb_build_object('chi', ch); end if;
      end if;
    end if;
    if o <> '{}'::jsonb then pend := pend || (o || jsonb_build_object('s', p)); end if;
  end loop;
  -- 鳴ける人がいてもいなくても、同じだけ待つ（だれが鳴けるか、ほかの人にわからないように）
  return st || jsonb_build_object('pend', pend, 'resp', '{}'::jsonb, 'phase', 'call', 'cwok', false,
                                  'timer_at', coalesce((st->>'now')::bigint, 0) + 600, 'win', (st->>'win')::int + 1);
end $$;

-- 暗槓・加槓（加槓は槍槓できる人がいれば、まず聞く）
create or replace function public._mj_selfkan(st jsonb, s int, k int) returns jsonb
language plpgsql volatile as $$
declare h int[] := _mj_hand(st, s); m jsonb; i int := 0; idx int := -1; t int; p int; pend jsonb := '[]';
begin
  for m in select * from jsonb_array_elements(st->'melds'->s) loop
    if m->>'k' = 'pon' and (m->'t'->>0)::int / 4 = k then idx := i; end if;
    i := i + 1;
  end loop;
  st := st || jsonb_build_object('ippatsu', '[false,false,false,false]'::jsonb, 'fd', '[false,false,false,false]'::jsonb,
                                 'calls', (st->>'calls')::int + 1, 'aopt', null);
  if idx >= 0 then
    t := (select x from unnest(h) x where x / 4 = k limit 1);
    st := _mj_set(st, 'hands', s, _mj_sorted(array_remove(h, t)));
    m := st->'melds'->s->idx;
    st := jsonb_set(st, array['melds', s::text, idx::text], m || jsonb_build_object('k', 'kakan', 't', _mj_sorted(_mj_ids(m->'t') || t)));
    st := _mj_log(st, jsonb_build_object('a', 'kakan', 's', s, 't', t));
    for p in select (s + q) % 4 from generate_series(1, 3) q loop
      if k = any(_mj_ids(st->'waits'->p)) and not _mj_furiten(st, p) and _mj_try(st, p, t, false, true) is not null then
        pend := pend || jsonb_build_object('s', p, 'ron', true);
      end if;
    end loop;
    -- 槍槓できる人がいてもいなくても、同じだけ待つ
    return st || jsonb_build_object('phase', 'rob', 'last', jsonb_build_object('s', s, 't', t), 'pend', pend, 'resp', '{}'::jsonb, 'drawn', null,
                                    'cwok', false, 'timer_at', coalesce((st->>'now')::bigint, 0) + 600, 'win', (st->>'win')::int + 1);
  else
    st := _mj_set(st, 'melds', s, (st->'melds'->s) || jsonb_build_object('k', 'ankan', 't', _mj_sorted(array(select x from unnest(h) x where x / 4 = k))));
    st := _mj_set(st, 'hands', s, _mj_sorted(array(select x from unnest(h) x where x / 4 <> k)));
    st := _mj_log(st, jsonb_build_object('a', 'ankan', 's', s, 'k', k));
  end if;
  st := _mj_set(st, 'kans', s, to_jsonb((st->'kans'->>s)::int + 1));
  st := st || jsonb_build_object('dora_n', (st->>'dora_n')::int + 1);
  return _mj_draw(st, s, true);
end $$;

-- いま考える番の席
create or replace function public._mj_pending(st jsonb) returns int[]
language sql immutable as $$
  select case when coalesce((st->>'over')::boolean, false) then '{}'::int[]
              when st->>'phase' = 'act' then array[(st->>'turn')::int]
              when st->>'phase' in ('call', 'rob') then coalesce(array(
                select (e->>'s')::int from jsonb_array_elements(st->'pend') e where not (st->'resp' ? (e->>'s'))
                 order by ((e->>'s')::int - (st->'last'->>'s')::int + 4) % 4), '{}')
              else '{}'::int[] end $$;

create or replace function public._mj_delay(st jsonb) returns int
language sql immutable as $$ select case when st->>'phase' = 'act' then 700 else 300 end $$;

-- 人・コンピューターの動き
--   act：{a: discard, t, riichi} / {a: tsumo} / {a: kan, k} / {a: kyuushu}
--   call・rob：{a: ron} / {a: pon, t} / {a: kan} / {a: chi, t} / {a: pass}
--   end：{a: ready}（次の局へ）。timer：時間がきたら次の局
create or replace function public._mj_act(st jsonb, s int, mv jsonb) returns jsonb
language plpgsql volatile as $$
declare a text := mv->>'a'; ph text := st->>'phase'; o jsonb; t int; k int; e jsonb; v jsonb; ls int;
begin
  if coalesce((st->>'over')::boolean, false) then raise exception 'このゲームはもう終わっています'; end if;
  if a = 'timer' then
    if st->>'timer_at' is null or coalesce((st->>'now')::bigint, 0) < (st->>'timer_at')::bigint then return st; end if;
    if ph = 'end' then return _mj_next_hand(st); end if;
    if ph in ('call', 'rob') then   -- 待つ時間がすぎた。みんな答えていれば決める
      st := st || jsonb_build_object('cwok', true, 'timer_at', null);
      if not exists (select 1 from jsonb_array_elements(st->'pend') e2 where not (st->'resp' ? (e2->>'s'))) then return _mj_resolve(st); end if;
    end if;
    return st;
  end if;
  if ph = 'end' then
    if a <> 'ready' then raise exception '次の局を待っています'; end if;
    st := _mj_set(st, 'ready', s, 'true');
    if (select coalesce(bool_and((st->'ready'->>(x::int))::boolean), true) from jsonb_array_elements_text(coalesce(st->'hum', '[]')) x) then
      return _mj_next_hand(st);
    end if;
    return st;
  end if;
  if ph = 'act' then
    if s <> (st->>'turn')::int then raise exception 'いまはあなたの番ではありません'; end if;
    o := st->'aopt';
    if a = 'tsumo' then
      if not coalesce((o->>'tsumo')::boolean, false) then raise exception 'ツモあがりできません'; end if;
      return _mj_win(st, s, null, (st->>'drawn')::int, true, false);
    end if;
    if a = 'kyuushu' then
      if not coalesce((o->>'kyuushu')::boolean, false) then raise exception '九種九牌ではありません'; end if;
      return _mj_abort(st, '九種九牌');
    end if;
    if a = 'kan' then
      k := (mv->>'k')::int;
      if k is null or not (k = any(_mj_ids(o->'kan'))) then raise exception 'そのカンはできません'; end if;
      return _mj_selfkan(st, s, k);
    end if;
    if a = 'discard' then
      t := (mv->>'t')::int;
      if t is null or not (t = any(_mj_ids(o->'discard'))) then raise exception 'その牌は捨てられません'; end if;
      if coalesce((mv->>'riichi')::boolean, false) then
        if not (t = any(_mj_ids(o->'riichi'))) then raise exception 'その牌を捨ててもテンパイにならないので、リーチできません'; end if;
        return _mj_discard(st, s, t, true);
      end if;
      return _mj_discard(st, s, t, false);
    end if;
    raise exception 'その動きはできません';
  end if;
  if ph in ('call', 'rob') then
    select e2 into e from jsonb_array_elements(st->'pend') e2 where (e2->>'s')::int = s;
    if e is null then raise exception 'いまは何もできません'; end if;
    if st->'resp' ? s::text then raise exception 'もう答えました'; end if;
    if a = 'ron' then
      if not coalesce((e->>'ron')::boolean, false) then raise exception 'ロンできません'; end if;
      v := '{"a": "ron"}';
    elsif a = 'pon' and ph = 'call' then
      if e->'pon' is null then raise exception 'ポンできません'; end if;
      v := coalesce((select x from jsonb_array_elements(e->'pon') x where x = _mj_sorted(_mj_ids(mv->'t'))), e->'pon'->0);
      v := jsonb_build_object('a', 'pon', 't', v);
    elsif a = 'kan' and ph = 'call' then
      if not coalesce((e->>'kan')::boolean, false) then raise exception 'カンできません'; end if;
      v := '{"a": "kan"}';
    elsif a = 'chi' and ph = 'call' then
      if e->'chi' is null then raise exception 'チーできません'; end if;
      v := (select x from jsonb_array_elements(e->'chi') x where x = _mj_sorted(_mj_ids(mv->'t')));
      if v is null then raise exception 'そのチーはできません'; end if;
      v := jsonb_build_object('a', 'chi', 't', v);
    elsif a = 'pass' then v := '{"a": "pass"}';
    else raise exception 'その動きはできません'; end if;
    st := jsonb_set(st, array['resp', s::text], v);
    if not coalesce((st->>'cwok')::boolean, false) then return st; end if;   -- 待つ時間がすぎるまでは決めない
    if not exists (select 1 from jsonb_array_elements(st->'pend') e2 where not (st->'resp' ? (e2->>'s'))) then return _mj_resolve(st); end if;
    if a = 'ron' then   -- 自分より前にロンできる人が答えていなければ待つ。いなければすぐ決まる
      ls := (st->'last'->>'s')::int;
      if not exists (select 1 from jsonb_array_elements(st->'pend') e2 where coalesce((e2->>'ron')::boolean, false) and not (st->'resp' ? (e2->>'s'))
                      and ((e2->>'s')::int - ls + 4) % 4 < (s - ls + 4) % 4) then
        return _mj_resolve(st);
      end if;
    end if;
    return st;
  end if;
  raise exception 'いまは何もできません';
end $$;

-- 見えるもの（自分の手牌だけ。局が終わったら、あがった人・テンパイの人の手）
create or replace function public._mj_view(st jsonb, me int) returns jsonb
language plpgsql immutable as $$
declare ph text := st->>'phase'; o jsonb := null; e jsonb; dn int := coalesce((st->>'dora_n')::int, 1);
begin
  if me is not null and ph = 'act' and (st->>'turn')::int = me then o := jsonb_build_object('act', st->'aopt');
  elsif me is not null and ph in ('call', 'rob') then
    select e2 into e from jsonb_array_elements(st->'pend') e2 where (e2->>'s')::int = me;
    if e is not null and not (st->'resp' ? me::text) then o := jsonb_build_object('call', e); end if;
  end if;
  return jsonb_build_object('rules', st->'rules', 'round', st->'round', 'kyoku', st->'kyoku', 'honba', st->'honba', 'kyotaku', st->'kyotaku',
    'scores', st->'scores', 'wall_n', jsonb_array_length(coalesce(st->'wall', '[]')),
    'dora', (select jsonb_agg(st->'dead'->(4 + q)) from generate_series(0, dn - 1) q),
    'melds', st->'melds', 'river', st->'river', 'riichi', st->'riichi',
    'counts', (select jsonb_agg(jsonb_array_length(st->'hands'->q) order by q) from generate_series(0, 3) q),
    'hand', case when me is null then null else st->'hands'->me end,
    'drawn', case when me is not null and (st->>'turn')::int = me and ph = 'act' then st->'drawn' else null end,
    'turn', st->'turn', 'phase', ph, 'last', st->'last', 'opts', o,
    'result', st->'result', 'ready', st->'ready', 'timer_at', st->'timer_at', 'log', st->'log',
    'furiten', case when me is null or ph in ('end', 'over') then null else to_jsonb(_mj_furiten(st, me)) end,
    'waits', case when me is null then null else st->'waits'->me end,
    'over', coalesce((st->>'over')::boolean, false), 'final', st->'final');
end $$;

-- ---------- 麻雀のコンピューター ----------
-- 残しておきたい度合い（低いものから捨てる）
create or replace function public._mj_tval(st jsonb, s int, c int[], k int) returns int
language plpgsql immutable as $$
declare v int := 0; dk int[];
begin
  dk := array(select _mj_dora_of((st->'dead'->>(4 + q))::int / 4) from generate_series(0, (st->>'dora_n')::int - 1) q);
  if k >= 27 then
    if c[k + 1] >= 2 then v := 10; end if;
    if k >= 31 or k = _mj_seatw(st, s) or k = 27 + (st->>'round')::int then v := v + 3; end if;
  else
    v := (c[k + 1] - 1) * 5;
    if k % 9 >= 1 and c[k] > 0 then v := v + 4; end if;
    if k % 9 <= 7 and c[k + 2] > 0 then v := v + 4; end if;
    if k % 9 >= 2 and c[k - 1] > 0 then v := v + 2; end if;
    if k % 9 <= 6 and c[k + 3] > 0 then v := v + 2; end if;
    v := v + case when k % 9 in (0, 8) then 0 when k % 9 in (1, 7) then 1 else 2 end;
  end if;
  return v + 3 * (select count(*) from unnest(dk) z where z = k);
end $$;

-- 安全度（リーチしている人に対して。高いほど安全）
create or replace function public._mj_safe(st jsonb, s int, k int) returns int
language plpgsql immutable as $$
declare p int; v int := 0; rk int[]; seen int;
begin
  for p in 0..3 loop
    continue when p = s or (st->'riichi'->>p)::int < 0;
    rk := array(select (r->>'t')::int / 4 from jsonb_array_elements(st->'river'->p) r);
    if k = any(rk) then v := v + 20;
    elsif k >= 27 then
      seen := (select count(*) from jsonb_array_elements(st->'river') rv, jsonb_array_elements(rv) r where (r->>'t')::int / 4 = k)
            + (select count(*) from jsonb_array_elements(st->'melds') mm, jsonb_array_elements(mm) m, jsonb_array_elements_text(m->'t') x where x::int / 4 = k);
      v := v + case when seen >= 3 then 18 when seen = 2 then 12 else 6 end;
    elsif (k % 9 between 3 and 5 and (k - 3) = any(rk) and (k + 3) = any(rk)) or (k % 9 <= 2 and (k + 3) = any(rk)) or (k % 9 >= 6 and (k - 3) = any(rk)) then
      v := v + 10;
    elsif k % 9 in (0, 8) then v := v + 4;
    elsif k % 9 in (1, 7) then v := v + 2;
    end if;
  end loop;
  return v;
end $$;

-- 見えている枚数（自分の手・捨て牌・鳴き・ドラ表示牌）
create or replace function public._mj_seen(st jsonb, s int, k int) returns int
language sql immutable as $$
  select (select count(*) from unnest(_mj_ids(st->'hands'->s)) x where x / 4 = k)
       + (select count(*) from jsonb_array_elements(st->'river') rv, jsonb_array_elements(rv) r where (r->>'t')::int / 4 = k and not (r->>'x')::boolean)
       + (select count(*) from jsonb_array_elements(st->'melds') mm, jsonb_array_elements(mm) m, jsonb_array_elements_text(m->'t') x where x::int / 4 = k)
       + (select count(*) from generate_series(0, (st->>'dora_n')::int - 1) q where (st->'dead'->>(4 + q))::int / 4 = k) $$;

-- 鳴いたあとの、いちばんよいシャンテン数（use：鳴きに使う牌の種類、forbid：捨てられない牌）
create or replace function public._mj_sh_after(c int[], use int[], forbid int[], nm int) returns int
language plpgsql volatile as $$
declare k int; best int := 99; s int; c2 int[];
begin
  foreach k in array use loop c[k + 1] := c[k + 1] - 1; end loop;
  for k in 0..33 loop
    continue when c[k + 1] = 0 or k = any(forbid);
    c2 := c; c2[k + 1] := c2[k + 1] - 1;
    s := _mj_shanten(c2, nm + 1);
    if s < best then best := s; end if;
  end loop;
  return best;
end $$;

create or replace function public._mj_cpu(st jsonb, s int) returns jsonb
language plpgsql volatile as $$
declare ph text := st->>'phase'; o jsonb; e jsonb; h int[]; c int[]; c2 int[]; nm int; k int; cur int; sh int; mn int := 99;
        cand int[]; riis int; ks int[]; bestk int; bestsc numeric; sc numeric; defend boolean; rl int[]; wv int; bw int := -1; bt int;
        yk int[]; hasyh boolean; tan boolean; xj jsonb; shs int[] := array_fill(99, array[34]);
begin
  if ph = 'act' then
    o := st->'aopt'; h := _mj_hand(st, s); c := _mj_cnt(h); nm := _mj_nm(st, s);
    if coalesce((o->>'tsumo')::boolean, false) then return '{"a": "tsumo"}'; end if;
    if coalesce((o->>'kyuushu')::boolean, false) and (select count(*) from generate_series(0, 33) q where _mj_yao(q) and c[q + 1] > 0) <= 10 then
      return '{"a": "kyuushu"}';
    end if;
    if (st->'riichi'->>s)::int >= 0 then
      if o->'kan' is not null then return jsonb_build_object('a', 'kan', 'k', (o->'kan'->>0)::int); end if;
      return jsonb_build_object('a', 'discard', 't', (st->>'drawn')::int);
    end if;
    cur := _mj_shanten(c, nm);
    if o->'kan' is not null then
      k := (o->'kan'->>0)::int;
      if c[k + 1] = 4 then
        c2 := c; c2[k + 1] := 0;
        if _mj_sh_after(c2, '{}', '{}', nm) <= cur then return jsonb_build_object('a', 'kan', 'k', k); end if;
      else
        return jsonb_build_object('a', 'kan', 'k', k);
      end if;
    end if;
    cand := _mj_ids(o->'discard');
    ks := array(select distinct x / 4 from unnest(cand) x);
    foreach k in array ks loop
      c2 := c; c2[k + 1] := c2[k + 1] - 1;
      shs[k + 1] := _mj_shanten(c2, nm);
      if shs[k + 1] < mn then mn := shs[k + 1]; end if;
    end loop;
    riis := (select count(*) from generate_series(0, 3) q where q <> s and (st->'riichi'->>q)::int >= 0);
    defend := riis > 0 and mn >= 2;
    -- テンパイになる捨て牌がいくつかあるなら、待ちの多いものを
    if mn = 0 then
      rl := _mj_ids(o->'riichi');
      foreach k in array ks loop
        continue when shs[k + 1] <> 0;
        h := array_remove(_mj_hand(st, s), (select max(x) from unnest(cand) x where x / 4 = k));
        wv := (select coalesce(sum(greatest(0, 4 - _mj_seen(st, s, w))), 0) from unnest(_mj_waits(h, nm)) w);
        if wv > bw then bw := wv; bestk := k; end if;
      end loop;
      bt := (select max(x) from unnest(cand) x where x / 4 = bestk);
      if not (bt = any(rl)) then bt := coalesce((select max(x) from unnest(rl) x where x / 4 = bestk), bt); end if;
      return jsonb_build_object('a', 'discard', 't', bt, 'riichi', bt = any(rl) and bw > 0);
    end if;
    bestsc := null;
    foreach k in array ks loop
      if defend then sc := -_mj_safe(st, s, k) * 100 + shs[k + 1] * 10 + _mj_tval(st, s, c, k) / 10.0;
      elsif riis > 0 then sc := shs[k + 1] * 100 - _mj_safe(st, s, k) * 2 + _mj_tval(st, s, c, k);
      else sc := shs[k + 1] * 100 + _mj_tval(st, s, c, k); end if;
      if bestsc is null or sc < bestsc then bestsc := sc; bestk := k; end if;
    end loop;
    bt := (select max(x) from unnest(cand) x where x / 4 = bestk);   -- 赤5はなるべく残す
    return jsonb_build_object('a', 'discard', 't', bt);
  end if;
  if ph in ('call', 'rob') then
    select e2 into e from jsonb_array_elements(st->'pend') e2 where (e2->>'s')::int = s;
    if coalesce((e->>'ron')::boolean, false) then return '{"a": "ron"}'; end if;
    if ph = 'rob' then return '{"a": "pass"}'; end if;
    h := _mj_hand(st, s); c := _mj_cnt(h); nm := _mj_nm(st, s); k := (st->'last'->>'t')::int / 4;
    cur := _mj_shanten(c, nm);
    yk := array[31, 32, 33, _mj_seatw(st, s), 27 + (st->>'round')::int];
    hasyh := exists (select 1 from jsonb_array_elements(st->'melds'->s) m where m->>'k' <> 'chi' and (m->'t'->>0)::int / 4 = any(yk));
    tan := not _mj_yao(k)
       and not exists (select 1 from jsonb_array_elements(st->'melds'->s) m, jsonb_array_elements_text(m->'t') t2 where _mj_yao(t2::int / 4))
       and (select count(*) from unnest(h) x where _mj_yao(x / 4)) <= 2;
    if e->'pon' is not null and (k = any(yk) or hasyh or tan) then
      if _mj_sh_after(c, array[k, k], array[k], nm) < cur then return jsonb_build_object('a', 'pon', 't', e->'pon'->0); end if;
    end if;
    if e->'chi' is not null and (hasyh or tan) then
      for xj in select * from jsonb_array_elements(e->'chi') loop
        ks := array(select y::int / 4 from jsonb_array_elements_text(xj) y);
        continue when tan and exists (select 1 from unnest(ks) z where _mj_yao(z));
        if _mj_sh_after(c, ks, _mj_kuikae_chi(k, least(ks[1], ks[2], k) - k), nm) < cur then return jsonb_build_object('a', 'chi', 't', xj); end if;
      end loop;
    end if;
    return '{"a": "pass"}';
  end if;
  return '{"a": "ready"}';
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
language sql immutable as $$
  select case g when 'reversi' then 'オセロ' when 'chess' then 'チェス' when 'shogi' then '将棋'
                when 'onecard' then 'ワンカード' when 'mahjong' then '麻雀' when 'auction' then '競り市'
                when 'koikoi' then '花札こいこい' else g end $$;

-- =====================================================================
-- 競り市（みんなで遊ぶ。競り上げ）：魚市場・骨董市
--   1回の競りで5品。品ごとに、見せる（3.5秒）→ 競り（値をつける）→ 落札（5秒） の順
--   競り：はじめは「せり始めの値」。だれかが値をつけると、7秒だれもつけなければ落札（はじめの12秒だれもつけなければ流れ）
--   値をつけると、その額をあずかる（ほかの人が上の値をつけたら返す）。落札したら、あずけた額をはらって、品の本当の値打ちを受け取る（そのまま損得）
--   それぞれ自分だけの「目利き」（値打ちの見立て。骨董は本物か偽物かの見立ても）が見える。市場の仲買人（コンピューター）2人もいつも競る
-- =====================================================================
create or replace function public._au_step(p bigint) returns bigint
language sql immutable as $$
  select coalesce((select min(v) from (select (m * (10::numeric ^ e))::bigint v from unnest(array[1, 2, 5]) m, generate_series(1, 9) e) z
                    where v >= greatest(p, 1) * 0.04), 10)
$$;
-- 次につけられるいちばん低い値
create or replace function public._au_min(st jsonb) returns bigint
language sql immutable as $$
  select case when coalesce((st->>'high')::int, -1) < 0 then (st->'lots'->((st->>'k')::int)->>'start')::bigint
              else (st->>'price')::bigint + _au_step((st->>'price')::bigint) end
$$;
-- 品をひとつつくる（nb：競る人の数＝席＋仲買人2人）
create or replace function public._au_lot(mk text, nb int) returns jsonb
language plpgsql volatile as $$
declare it record; w int; v numeric; vg numeric; e0 numeric; fake boolean := false; est jsonb := '[]'; hint jsonb := '[]'; rs jsonb := '[]';
        i int; e numeric; info text; st0 bigint; step bigint; h text; ex numeric;
begin
  if mk = 'fish' then
    select * into it from (values
      ('本マグロ', '🐟', 'kg', 90, 260, 180, 700, ''), ('ミナミマグロ', '🐟', 'kg', 50, 120, 120, 380, ''), ('メバチマグロ', '🐟', 'kg', 30, 80, 80, 260, ''),
      ('タラバガニ', '🦀', 'box', 5, 0, 12000, 45000, '杯'), ('毛ガニ', '🦀', 'box', 10, 0, 8000, 30000, '杯'), ('ズワイガニ', '🦀', 'box', 8, 0, 10000, 40000, '杯'),
      ('ウニ', '🍣', 'box', 10, 0, 6000, 40000, '箱'), ('イセエビ', '🦞', 'box', 10, 0, 10000, 35000, '尾'), ('アワビ', '🐚', 'box', 20, 0, 8000, 30000, '個'),
      ('クエ', '🐟', 'kg', 15, 40, 300, 900, ''), ('ノドグロ', '🐟', 'box', 15, 0, 8000, 28000, '尾'), ('関サバ', '🐟', 'box', 12, 0, 4000, 15000, '尾'),
      ('トラフグ', '🐡', 'kg', 10, 30, 400, 1200, ''), ('寒ブリ', '🐟', 'box', 5, 0, 6000, 20000, '本'), ('金目鯛', '🐟', 'box', 10, 0, 7000, 24000, '尾')
    ) x(nm, em, kind, a, b, lo, hi, cnt) order by random() limit 1;
    info := (array['大間', '銚子', '焼津', '境港', '釧路', '稚内', '羅臼', '枕崎', '下関', '氷見', '気仙沼', '長崎', '函館', '三崎'])[1 + floor(random() * 14)::int];
    if it.kind = 'kg' then
      w := it.a + floor(random() * (it.b - it.a + 1))::int;
      v := w * exp(ln(it.lo) + random() * (ln(it.hi) - ln(it.lo))) * exp(_randn() * 0.15);
      e0 := w * sqrt(it.lo::numeric * it.hi);
      info := info || '・' || w || 'kg';
    else
      v := exp(ln(it.lo) + random() * (ln(it.hi) - ln(it.lo))) * exp(_randn() * 0.15);
      e0 := sqrt(it.lo::numeric * it.hi);
      info := info || '・' || it.a || it.cnt || '入り';
    end if;
    vg := v;
  else
    select * into it from (values
      ('古伊万里の壺', '🏺', 20000, 120000), ('備前焼の壺', '🏺', 10000, 60000), ('山水画の掛け軸', '📜', 30000, 250000), ('浮世絵の版画', '🖼', 15000, 150000),
      ('楽焼の茶碗', '🍵', 20000, 180000), ('日本刀', '⚔', 40000, 300000), ('古銭の束', '🪙', 3000, 25000), ('金屏風', '🖼', 50000, 200000),
      ('懐中時計', '🕰', 8000, 60000), ('蒔絵の文箱', '📦', 10000, 80000), ('南部鉄瓶', '🫖', 5000, 40000), ('螺鈿の手鏡', '🪞', 6000, 50000)
    ) x(nm, em, lo, hi) order by random() limit 1;
    vg := exp(ln(it.lo) + random() * (ln(it.hi) - ln(it.lo)));
    fake := random() < 0.25;
    v := case when fake then vg * (0.03 + random() * 0.05) else vg end;
    e0 := sqrt(it.lo::numeric * it.hi) * 0.764;
    info := (array['室町', '桃山', '江戸前期', '江戸中期', '江戸後期', '明治', '大正'])[1 + floor(random() * 7)::int] || '・'
         || (array['共箱あり', '箱なし', 'ほぼ無傷', '少しきず', '鑑定書つき', '旧家の蔵から'])[1 + floor(random() * 6)::int];
  end if;
  v := greatest(round(v / 10) * 10, 10);
  for i in 1..nb loop
    e := round(vg * exp(_randn() * 0.16) / 10) * 10;
    est := est || to_jsonb(e);
    if mk = 'fish' then
      h := null; ex := e;
    else
      h := case when (fake and random() < 0.75) or (not fake and random() < 0.25) then 'sus' else 'ok' end;
      ex := e * case when h = 'sus' then 0.525 else 0.905 end;     -- 見立てから考えた値打ち
    end if;
    hint := hint || to_jsonb(h);
    rs := rs || to_jsonb(round(ex * (0.88 + random() * 0.14)));  -- コンピューターなら、ここまでは値をつける
  end loop;
  step := _au_step((e0 * 0.45)::bigint);
  st0 := greatest(round(e0 * 0.45 / step) * step, step);
  return jsonb_build_object('nm', it.nm, 'em', it.em, 'info', info, 'mk', mk, 'v', v::bigint, 'fake', fake,
                            'start', st0, 'est', est, 'hint', hint, 'rs', rs);
end $$;

create or replace function public._au_init(n int, opts jsonb) returns jsonb
language plpgsql volatile as $$
declare mk text := coalesce(opts->>'market', 'fish'); lots jsonb := '[]'; i int; t bigint := _kb_ms(_now());
begin
  if mk not in ('fish', 'antique', 'mix') then mk := 'fish'; end if;
  for i in 1..5 loop
    lots := lots || _au_lot(case when mk = 'mix' then (case when random() < 0.5 then 'fish' else 'antique' end) else mk end, n + 2);
  end loop;
  return jsonb_build_object('g', 'auction', 'market', mk, 'n', n, 'nb', n + 2, 'lots', lots, 'k', 0, 'phase', 'show',
    'price', null, 'high', -1, 't_next', t + 3500, 't_close', null, 'plan', (select jsonb_agg(null::int) from generate_series(1, n + 2)),
    'bids', '[]'::jsonb, 'pnl', (select jsonb_agg(0) from generate_series(1, n)), 'won', (select jsonb_agg(0) from generate_series(1, n)),
    'timer_at', t + 3500, 'over', false);
end $$;

-- コンピューター（席のコンピューターと市場の仲買人2人）の次に値をつける時刻を決めなおす
create or replace function public._au_plan(st jsonb, t bigint) returns jsonb
language plpgsql volatile as $$
declare nb int := (st->>'nb')::int; n int := (st->>'n')::int; k int := (st->>'k')::int; b int; mn bigint := _au_min(st); pl jsonb := '[]';
        cp int[] := array(select jsonb_array_elements_text(coalesce(st->'act', '[]'))::int); hi int := coalesce((st->>'high')::int, -1);
begin
  for b in 0..nb - 1 loop
    if b = any(cp) and b <> hi and (st->'lots'->k->'rs'->>b)::bigint >= mn then
      pl := pl || to_jsonb(t + 900 + floor(random() * 2100)::bigint);
    else
      pl := pl || 'null'::jsonb;
    end if;
  end loop;
  return jsonb_set(st, '{plan}', pl);
end $$;

-- 次のできごとの時刻
create or replace function public._au_next(st jsonb) returns jsonb
language plpgsql immutable as $$
declare t bigint; x jsonb;
begin
  if coalesce((st->>'over')::boolean, false) then return st - 'timer_at'; end if;
  if st->>'phase' = 'bid' then
    t := (st->>'t_close')::bigint;
    for x in select * from jsonb_array_elements(st->'plan') loop
      if jsonb_typeof(x) = 'number' and (x #>> '{}')::bigint < t then t := (x #>> '{}')::bigint; end if;
    end loop;
  else
    t := (st->>'t_next')::bigint;
  end if;
  return jsonb_set(st, '{timer_at}', to_jsonb(t));
end $$;

-- 値をつける（b：競る人。席か仲買人）
create or replace function public._au_bid(st jsonb, b int, x bigint, t bigint) returns jsonb
language plpgsql volatile as $$
declare bids jsonb := coalesce(st->'bids', '[]');
begin
  bids := bids || jsonb_build_object('b', b, 'p', x, 't', t);
  if jsonb_array_length(bids) > 8 then bids := bids - 0; end if;
  st := st || jsonb_build_object('price', x, 'high', b, 't_close', t + 7000, 'bids', bids);
  return _au_plan(st, t);
end $$;

-- 落札（または流れ）
create or replace function public._au_close(st jsonb, t bigint) returns jsonb
language plpgsql volatile as $$
declare k int := (st->>'k')::int; n int := (st->>'n')::int; hi int := coalesce((st->>'high')::int, -1); p bigint := (st->>'price')::bigint;
        v bigint := (st->'lots'->k->>'v')::bigint;
begin
  st := jsonb_set(st, array['lots', k::text, 'res'], jsonb_build_object('w', hi, 'p', case when hi >= 0 then p end));
  if hi >= 0 and hi < n then
    st := jsonb_set(st, array['pnl', hi::text], to_jsonb((st->'pnl'->>hi)::bigint + v - p));
    st := jsonb_set(st, array['won', hi::text], to_jsonb((st->'won'->>hi)::int + 1));
  end if;
  return st || jsonb_build_object('phase', 'sold', 't_next', t + 5000, 'plan', (select jsonb_agg(null::int) from generate_series(1, (st->>'nb')::int)));
end $$;

create or replace function public._au_act(st jsonb, s int, mv jsonb) returns jsonb
language plpgsql volatile as $$
declare t bigint := coalesce((st->>'now')::bigint, _kb_ms(_now())); k int := (st->>'k')::int; n int := (st->>'n')::int; x bigint; mn bigint;
        b int; bt bigint; pb jsonb; i int; best int; bestt bigint;
begin
  if coalesce((st->>'over')::boolean, false) then raise exception 'この競りはもう終わりました'; end if;
  if s >= 0 then   -- 人が値をつける
    if mv->>'a' <> 'bid' then raise exception 'できない操作です'; end if;
    if st->>'phase' = 'show' then raise exception 'まだ競りが始まっていません'; end if;
    if st->>'phase' <> 'bid' then raise exception 'この品の競りは終わりました'; end if;
    if t >= (st->>'t_close')::bigint then raise exception 'この品の競りは終わりました'; end if;
    if coalesce((st->>'high')::int, -1) = s then raise exception 'いちばん高い値をつけているのは、あなたです'; end if;
    if st->'lots'->k->>'seller' is not null and (st->'lots'->k->>'seller')::int = s then raise exception '自分の魚には値をつけられません'; end if;
    x := (mv->>'x')::bigint; mn := _au_min(st);
    if x is null or x < mn then raise exception '% X以上をつけてください', _fmt(mn); end if;
    if x > mn + 50 * _au_step(mn) then raise exception '一度に上げられるのは % Xまでです', _fmt(mn + 50 * _au_step(mn)); end if;
    return _au_next(_au_bid(st, s, x, t));
  end if;
  -- 時間のできごと
  if st->>'phase' = 'show' then
    -- この品で競るコンピューター（席のコンピューターと市場の仲買人から、3人まで）
    st := st || jsonb_build_object('phase', 'bid', 'price', null, 'high', -1, 't_close', t + 12000, 'bids', '[]'::jsonb,
      'act', (select coalesce(jsonb_agg(z.q), '[]'::jsonb) from (select g.q from generate_series(0, (st->>'nb')::int - 1) g(q)
               where g.q >= n or g.q in (select jsonb_array_elements_text(coalesce(st->'cpus', '[]'))::int) order by random() limit 3) z));
    return _au_next(_au_plan(st, t));
  end if;
  if st->>'phase' = 'bid' then
    -- いちばん早いコンピューター（時刻が来ていれば、落札より先）
    best := null; bestt := null; i := 0;
    for pb in select * from jsonb_array_elements(st->'plan') loop
      if jsonb_typeof(pb) = 'number' and (pb #>> '{}')::bigint <= t and (bestt is null or (pb #>> '{}')::bigint < bestt) then best := i; bestt := (pb #>> '{}')::bigint; end if;
      i := i + 1;
    end loop;
    if best is not null and bestt <= (st->>'t_close')::bigint then
      mn := _au_min(st);
      if (st->'lots'->k->'rs'->>best)::bigint >= mn and coalesce((st->>'high')::int, -1) <> best then
        bt := (st->'lots'->k->'rs'->>best)::bigint;
        x := mn;
        if mn < bt * 0.6 then          -- まだずっと安いときは、一気に上げる（見立ての5〜7割まで）
          x := greatest(mn, (round(bt * (0.5 + random() * 0.2) / _au_step(mn)) * _au_step(mn))::bigint);
        elsif random() < 0.15 and bt >= mn + _au_step(mn) then   -- ときどき2段上げ
          x := mn + _au_step(mn);
        end if;
        return _au_next(_au_bid(st, best, least(x, greatest(bt, mn)), t));
      end if;
      return _au_next(jsonb_set(st, array['plan', best::text], 'null'::jsonb));
    end if;
    if t >= (st->>'t_close')::bigint then return _au_next(_au_close(st, t)); end if;
    return _au_next(st);
  end if;
  if st->>'phase' = 'sold' then
    if k + 1 >= jsonb_array_length(st->'lots') then
      st := st || jsonb_build_object('phase', 'end', 'over', true, 'why', '5品の競りが終わりました');
      return _au_next(st || jsonb_build_object('final', _au_final(st)));
    end if;
    return _au_next(st || jsonb_build_object('k', k + 1, 'phase', 'show', 't_next', t + 3500, 'price', null, 'high', -1, 'bids', '[]'::jsonb));
  end if;
  return st;
end $$;

-- 順位（もうけの多い順）
create or replace function public._au_final(st jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('rank', (select jsonb_agg(i order by (st->'pnl'->>i)::bigint desc, i) from generate_series(0, (st->>'n')::int - 1) i),
                            'v', st->'pnl', 'scale', 1, 'ref', 'best')
$$;

-- 見せる形（値打ちは落札のあとだけ。目利きは自分の分だけ）
create or replace function public._au_view(st jsonb, me int) returns jsonb
language plpgsql immutable as $$
declare k int := (st->>'k')::int; lot jsonb := st->'lots'->k; done jsonb := '[]'; i int; l jsonb; open boolean;
begin
  for i in 0..jsonb_array_length(st->'lots') - 1 loop
    l := st->'lots'->i;
    open := l ? 'res';
    if i < k or (i = k and open) then
      done := done || jsonb_build_object('nm', l->'nm', 'em', l->'em', 'info', l->'info', 'mk', l->'mk', 'start', l->'start', 'res', l->'res', 'v', l->'v', 'fake', l->'fake', 'by', l->'by');
    end if;
  end loop;
  return jsonb_build_object('g', 'auction', 'market', st->'market', 'n', st->'n', 'nb', st->'nb', 'k', k, 'lots_n', jsonb_array_length(st->'lots'),
    'phase', st->'phase', 'price', st->'price', 'high', st->'high', 'min', case when st->>'phase' = 'bid' then _au_min(st) end,
    'step', case when st->>'phase' = 'bid' then _au_step(_au_min(st)) end,
    't_close', st->'t_close', 't_next', st->'t_next', 'timer_at', st->'timer_at', 'bids', st->'bids', 'pnl', st->'pnl', 'won', st->'won',
    'cpus', coalesce(st->'cpus', '[]'), 'over', coalesce(st->'over', 'false'), 'final', st->'final', 'why', st->'why',
    'lot', case when st->>'phase' in ('show', 'bid', 'sold') then jsonb_build_object('nm', lot->'nm', 'em', lot->'em', 'info', lot->'info', 'mk', lot->'mk', 'start', lot->'start',
             'by', lot->'by', 'own', coalesce(me is not null and lot->>'seller' is not null and (lot->>'seller')::int = me, false)) end,
    'my', case when me is not null and me >= 0 and st->>'phase' in ('show', 'bid', 'sold') then
            jsonb_build_object('est', lot->'est'->me, 'hint', lot->'hint'->me) end,
    'done', done);
end $$;

-- 値をつける前に、その額をあずかる（ゲストは遊べない）
create or replace function public._au_hold(u uuid, mv jsonb) returns void
language plpgsql set search_path = public as $$
declare x bigint;
begin
  if coalesce(mv->>'a', '') <> 'bid' then return; end if;
  if _is_guest(u) then raise exception '競り市はゲストでは遊べません（本登録すると遊べます）'; end if;
  x := (mv->>'x')::bigint;
  if x is null or x < 1 then raise exception '値を入れてください'; end if;
  perform _take(u, x);
end $$;

-- お金：値を上書きされた人に返す・落札した人は値打ちを受け取る（a：前、b：あと）
create or replace function public._au_money(rid bigint, seats uuid[], a jsonb, b jsonb) returns void
language plpgsql set search_path = public as $$
declare n int := (b->>'n')::int; ak int := (a->>'k')::int; ah int := coalesce((a->>'high')::int, -1); bh int := coalesce((b->>'high')::int, -1);
        lot jsonb; w int; p bigint; v bigint; uid uuid;
begin
  if a->>'phase' <> 'bid' then return; end if;
  -- 上書きされた（同じ品のうちに、いちばん高い人が変わった）
  if b->>'phase' = 'bid' and (b->>'k')::int = ak and bh <> ah and ah >= 0 and ah < n and seats[ah + 1] is not null then
    update profiles set balance = balance + (a->>'price')::bigint where id = seats[ah + 1];
  end if;
  -- 落札が決まった
  if b->>'phase' <> 'bid' and (b->'lots'->ak) ? 'res' then
    lot := b->'lots'->ak; w := coalesce((lot->'res'->>'w')::int, -1); p := (lot->'res'->>'p')::bigint;
    if w >= 0 and w < n and seats[w + 1] is not null then
      uid := seats[w + 1]; v := (lot->>'v')::bigint;
      perform _give(uid, v);
      perform _log(uid, 'auction', p, v, jsonb_build_object('room', rid, 'lot', lot->>'nm', 'fake', coalesce((lot->>'fake')::boolean, false)));
    end if;
    if lot ? 'cid' then perform _fi_sold((lot->>'cid')::bigint, w, p, rid); end if;   -- 釣った魚の出品
  end if;
end $$;

-- やめるとき（長すぎる競り）：あずかっているお金を返す
create or replace function public._au_abort(rid bigint) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; h int;
begin
  select * into r from game_rooms where id = rid for update;
  if not found or r.status <> 'playing' then return; end if;
  h := coalesce((r.state->>'high')::int, -1);
  if r.state->>'phase' = 'bid' and h >= 0 and h < (r.state->>'n')::int and r.seats[h + 1] is not null then
    update profiles set balance = balance + (r.state->>'price')::bigint where id = r.seats[h + 1];
  end if;
  update game_rooms set status = 'finished', finished_at = _now(), reason = '時間がかかりすぎたので終わり（あずかっていた額は返しました）',
         state = state || jsonb_build_object('over', true, 'phase', 'end') where id = rid;
  update fi_lots set status = 'queued', room_id = null where room_id = rid and status = 'auction';   -- 競られなかった出品はもどす
end $$;

-- 毎分：人が見ていなくても競りを進める（2時間たったら終わり）
create or replace function public._au_cron() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from game_rooms where game = 'auction' and status = 'waiting' and created_at < _now() - interval '1 day' for update skip locked loop
    perform _room_cancel(r.id, true);
  end loop;
  for r in select id, started_at from game_rooms where game = 'auction' and status = 'playing' for update skip locked loop
    if r.started_at < _now() - interval '2 hours' then perform _au_abort(r.id);
    else perform _room_tick(r.id, 150); end if;
    n := n + 1;
  end loop;
  return n;
end $$;
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-auction', '* * * * *', 'select public._au_cron()');
  end if;
end $$;

-- =====================================================================
-- 花札こいこい（ふたり。3・6・12か月。人どうし・コンピューターとも）
--   札：0〜47（月 = id / 4）。0 松・1 梅・2 桜・3 藤・4 菖蒲・5 牡丹・6 萩・7 芒・8 菊・9 紅葉・10 柳・11 桐
--   同じ月の中では、強い札ほど番号が小さい（光・タネ → 短冊 → カス）
--   光　：0 松に鶴・8 桜に幕・28 芒に月・40 柳に小野道風（雨）・44 桐に鳳凰
--   タネ：4 梅に鶯・12 藤に不如帰・16 菖蒲に八橋・20 牡丹に蝶・24 萩に猪・29 芒に雁・32 菊に盃・36 紅葉に鹿・41 柳に燕
--   短冊：1・5・9 赤短（あかよろし・みよしの）、21・33・37 青短、13・17・25・42 短冊
--   カス：のこりの24枚（菊に盃はカスにも数える）
--   役　：五光10・四光8・雨四光7・三光5・花見で一杯5・月見で一杯5・猪鹿蝶5・赤短5・青短5（両方で10）
--         タネ5枚で1・タン5枚で1・カス10枚で1（1枚ふえるごとに+1）。配ったとき：手四6・くっつき6
--   7点以上は2倍。相手がこいこいしたあとに上がると、さらに2倍。だれも上がらなければ親権（親に6点）
--   場に同じ月が4枚配られたら配りなおし。場に同じ月が3枚あるとき、4枚目を出した人が全部とる
-- =====================================================================
create or replace function public._kk_ids(j jsonb) returns int[]
language sql immutable as $$ select coalesce(array(select jsonb_array_elements_text(j)::int), '{}') $$;

create or replace function public._kk_sort(a int[]) returns int[]
language sql immutable as $$ select coalesce(array(select x from unnest(a) x order by x), '{}') $$;

-- 札の種類（L 光・T タネ・R 短冊・K カス）
create or replace function public._kk_kind(c int) returns text
language sql immutable as $$
  select case when c in (0, 8, 28, 40, 44) then 'L'
              when c in (4, 12, 16, 20, 24, 29, 32, 36, 41) then 'T'
              when c in (1, 5, 9, 13, 17, 21, 25, 33, 37, 42) then 'R'
              else 'K' end $$;

-- とった札でできている役（[[名前, 点], ...]）
create or replace function public._kk_yaku(cs int[]) returns jsonb
language plpgsql immutable as $$
declare y jsonb := '[]'; l int; t int; r int; k int; rain boolean; aka int; ao int;
begin
  cs := coalesce(cs, '{}');
  l := (select count(*) from unnest(cs) c where c in (0, 8, 28, 40, 44));
  rain := 40 = any(cs);
  t := (select count(*) from unnest(cs) c where c in (4, 12, 16, 20, 24, 29, 32, 36, 41));
  r := (select count(*) from unnest(cs) c where c in (1, 5, 9, 13, 17, 21, 25, 33, 37, 42));
  k := (select count(*) from unnest(cs) c where _kk_kind(c) = 'K') + case when 32 = any(cs) then 1 else 0 end;   -- 菊に盃はカスにも数える
  aka := (select count(*) from unnest(cs) c where c in (1, 5, 9));
  ao := (select count(*) from unnest(cs) c where c in (21, 33, 37));
  if l = 5 then y := y || '[["五光", 10]]';
  elsif l = 4 and not rain then y := y || '[["四光", 8]]';
  elsif l = 4 then y := y || '[["雨四光", 7]]';
  elsif l = 3 and not rain then y := y || '[["三光", 5]]';
  end if;
  if 8 = any(cs) and 32 = any(cs) then y := y || '[["花見で一杯", 5]]'; end if;
  if 28 = any(cs) and 32 = any(cs) then y := y || '[["月見で一杯", 5]]'; end if;
  if 20 = any(cs) and 24 = any(cs) and 36 = any(cs) then y := y || '[["猪鹿蝶", 5]]'; end if;
  if aka = 3 and ao = 3 then y := y || '[["赤短・青短", 10]]';
  elsif aka = 3 then y := y || '[["赤短", 5]]';
  elsif ao = 3 then y := y || '[["青短", 5]]';
  end if;
  if t >= 5 then y := y || jsonb_build_array(jsonb_build_array('タネ', t - 4)); end if;
  if r >= 5 then y := y || jsonb_build_array(jsonb_build_array('タン', r - 4)); end if;
  if k >= 10 then y := y || jsonb_build_array(jsonb_build_array('カス', k - 9)); end if;
  return y;
end $$;

create or replace function public._kk_pts(y jsonb) returns int
language sql immutable as $$ select coalesce(sum((e->>1)::int), 0)::int from jsonb_array_elements(coalesce(y, '[]'::jsonb)) e $$;

-- はじめの手札の手四（同じ月4枚）・くっつき（同じ月2枚が4組）
create or replace function public._kk_teshi(h int[]) returns text
language sql immutable as $$
  select case when exists (select 1 from unnest(h) c group by c / 4 having count(*) = 4) then '手四'
              when cardinality(h) = 8 and (select bool_and(n = 2) from (select count(*) n from unnest(h) c group by c / 4) z) then 'くっつき'
              else null end $$;

create or replace function public._kk_log(st jsonb, e jsonb) returns jsonb
language sql immutable as $$
  select st || jsonb_build_object('log', (select coalesce(jsonb_agg(x order by i), '[]'::jsonb) from (
     select x, i from jsonb_array_elements(coalesce(st->'log', '[]'::jsonb) || jsonb_build_array(e)) with ordinality z(x, i) order by i desc limit 12) w)) $$;

-- 点を足す
create or replace function public._kk_add(st jsonb, s int, p int) returns jsonb
language sql immutable as $$
  select jsonb_set(st, '{score}', jsonb_set(st->'score', array[s::text], to_jsonb((st->'score'->>s)::int + p))) $$;

-- 順位：点の多い順（同じ点なら引き分け）。点数で分けるときは、3か月10点・6か月20点・12か月30点の差で賭け金ぶん
create or replace function public._kk_final(st jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('rank', case when (st->'score'->>0)::int >= (st->'score'->>1)::int then '[0,1]'::jsonb else '[1,0]'::jsonb end,
    'v', st->'score', 'scale', case (st->>'months')::int when 3 then 10 when 6 then 20 else 30 end, 'ref', 'best',
    'draw', (st->'score'->>0)::int = (st->'score'->>1)::int) $$;

-- 月の終わり（nxt：次の月の親）。最後の月なら、そこでおしまい
create or replace function public._kk_end(st jsonb, res jsonb, nxt int) returns jsonb
language plpgsql volatile as $$
declare m int := (st->>'mon')::int; fin boolean := m + 1 >= (st->>'months')::int;
begin
  st := st || jsonb_build_object('phase', 'end', 'result', res || jsonb_build_object('score', st->'score', 'mon', m),
          'hist', coalesce(st->'hist', '[]'::jsonb) || jsonb_build_object('w', coalesce((res->>'s')::int, -1), 'p', coalesce((res->>'pts')::int, 0), 'k', res->>'kind'),
          'next_oya', nxt, 'ready', '[false,false]'::jsonb, 'drawn', null, 'opts', null, 'win', coalesce((st->>'win')::int, 0) + 1,
          'timer_at', case when fin then null else coalesce((st->>'now')::bigint, 0) + 20000 end);
  if fin then
    st := st || jsonb_build_object('over', true, 'why', format('%sか月が終わりました', st->>'months'));
    st := st || jsonb_build_object('final', _kk_final(st));
  end if;
  return st;
end $$;

-- 配る（場に同じ月が4枚なら配りなおし）。手四・くっつきは、そこで6点（親が先）
create or replace function public._kk_deal(st jsonb) returns jsonb
language plpgsql volatile as $$
declare d int[]; f int[]; h0 int[]; h1 int[]; o int := (st->>'oya')::int; t0 text; t1 text; w int; nm text;
begin
  loop
    d := array(select g from generate_series(0, 47) g order by random());
    h0 := d[1:8]; h1 := d[9:16]; f := d[17:24]; d := d[25:48];
    exit when not exists (select 1 from unnest(f) c group by c / 4 having count(*) = 4);
  end loop;
  st := st || jsonb_build_object('hands', jsonb_build_array(to_jsonb(_kk_sort(h0)), to_jsonb(_kk_sort(h1))), 'field', to_jsonb(_kk_sort(f)), 'deck', to_jsonb(d),
          'took', '[[],[]]'::jsonb, 'koi', '[0,0]'::jsonb, 'yp', '[0,0]'::jsonb, 'turn', o, 'phase', 'play', 'drawn', null, 'opts', null,
          'lt', '[null,null]'::jsonb, 'log', '[]'::jsonb, 'result', null, 'ready', '[false,false]'::jsonb, 'timer_at', null,
          'win', coalesce((st->>'win')::int, 0) + 1);
  t0 := _kk_teshi(_kk_ids(st->'hands'->o)); t1 := _kk_teshi(_kk_ids(st->'hands'->(1 - o)));
  if t0 is not null then w := o; nm := t0;
  elsif t1 is not null then w := 1 - o; nm := t1;
  end if;
  if w is not null then
    st := _kk_add(st, w, 6);
    return _kk_end(st, jsonb_build_object('kind', 'teshi', 's', w, 'name', nm, 'pts', 6, 'hand', st->'hands'->w), w);
  end if;
  return st;
end $$;

-- はじめ：親決め（ひとり1枚ずつめくって、月の早いほう。同じ月なら強い札のほう）
create or replace function public._kk_init(opts jsonb) returns jsonb
language plpgsql volatile as $$
declare c int[]; mo int := case when opts->>'months' in ('3', '6', '12') then (opts->>'months')::int else 6 end;
begin
  c := array(select g from generate_series(0, 47) g order by random() limit 2);
  return _kk_deal(jsonb_build_object('n', 2, 'months', mo, 'mon', 0, 'oya', case when c[1] < c[2] then 0 else 1 end, 'score', '[0,0]'::jsonb,
                  'hist', '[]'::jsonb, 'oyagime', to_jsonb(c), 'tn', 0, 'win', 0, 'over', false, 'now', _kb_ms(_now())));
end $$;

-- 次の月
create or replace function public._kk_next(st jsonb) returns jsonb
language plpgsql volatile as $$
begin
  st := st || jsonb_build_object('mon', (st->>'mon')::int + 1, 'oya', coalesce((st->>'next_oya')::int, (st->>'oya')::int), 'next_oya', null);
  return _kk_deal(st);
end $$;

-- 札を場に出す（同じ月の札があればとる：1枚ならそれ、2枚なら t をえらぶ、3枚なら全部）。とった札は _g に
create or replace function public._kk_put(st jsonb, s int, c int, t int) returns jsonb
language plpgsql immutable as $$
declare f int[] := _kk_ids(st->'field'); m int[]; g int[];
begin
  m := array(select x from unnest(f) x where x / 4 = c / 4 order by x);
  if cardinality(m) = 0 then
    return st || jsonb_build_object('field', to_jsonb(_kk_sort(f || c)), '_g', '[]'::jsonb);
  end if;
  if cardinality(m) = 2 then
    if t is null or not (t = any(m)) then raise exception 'どちらの札をとるか、えらんでください'; end if;
    g := array[c, t];
  elsif cardinality(m) = 1 then g := array[c, m[1]];
  else g := c || m;
  end if;
  return st || jsonb_build_object('field', to_jsonb(array(select x from unnest(f) x where not (x = any(g)) order by x)), '_g', to_jsonb(g),
                                  'took', jsonb_set(st->'took', array[s::text], to_jsonb(_kk_sort(_kk_ids(st->'took'->s) || g))));
end $$;

-- 番を相手へ。ふたりとも手札がなくなったら、親権（親に6点）
create or replace function public._kk_pass(st jsonb, s int) returns jsonb
language plpgsql volatile as $$
declare o int := (st->>'oya')::int;
begin
  if jsonb_array_length(st->'hands'->0) = 0 and jsonb_array_length(st->'hands'->1) = 0 then
    st := _kk_add(st, o, 6);
    st := _kk_log(st, jsonb_build_object('a', 'oyaken', 's', o));
    return _kk_end(st, jsonb_build_object('kind', 'oyaken', 's', o, 'pts', 6), o);
  end if;
  return st || jsonb_build_object('turn', 1 - s, 'phase', 'play', 'win', (st->>'win')::int + 1);
end $$;

-- 勝負（上がり）：役の点の合計。7点以上で2倍、相手がこいこいしていたら2倍
create or replace function public._kk_win(st jsonb, s int, auto boolean) returns jsonb
language plpgsql volatile as $$
declare y jsonb := _kk_yaku(_kk_ids(st->'took'->s)); b int := _kk_pts(y); m7 boolean := b >= 7;
        mk boolean := (st->'koi'->>(1 - s))::int > 0; p int;
begin
  p := b * (case when m7 then 2 else 1 end) * (case when mk then 2 else 1 end);
  st := _kk_add(st, s, p);
  st := _kk_log(st, jsonb_build_object('a', 'stop', 's', s, 'auto', auto));
  return _kk_end(st, jsonb_build_object('kind', 'win', 's', s, 'yaku', y, 'base', b, 'm7', m7, 'mk', mk, 'pts', p,
                                        'koi', (st->'koi'->>s)::int, 'auto', auto, 'took', st->'took'->s), s);
end $$;

-- 1回の番が終わったあと：役がふえたら「こいこい」か「勝負」。最後の札なら、そのまま勝負
create or replace function public._kk_after(st jsonb, s int) returns jsonb
language plpgsql volatile as $$
declare p int := _kk_pts(_kk_yaku(_kk_ids(st->'took'->s))); e jsonb;
begin
  e := (st->'cur') || jsonb_build_object('n', coalesce((st->>'tn')::int, 0) + 1);
  st := (st - 'cur') || jsonb_build_object('lt', jsonb_set(st->'lt', array[s::text], e), 'tn', coalesce((st->>'tn')::int, 0) + 1);
  st := _kk_log(st, e || jsonb_build_object('a', 'turn', 's', s));
  if p > (st->'yp'->>s)::int then
    if jsonb_array_length(st->'hands'->s) = 0 then return _kk_win(st, s, true); end if;
    return st || jsonb_build_object('phase', 'koi', 'win', (st->>'win')::int + 1);
  end if;
  return _kk_pass(st, s);
end $$;

-- 山札を1枚めくる（場に同じ月が2枚あるときは、どちらをとるかえらぶ）
create or replace function public._kk_draw(st jsonb, s int) returns jsonb
language plpgsql volatile as $$
declare d int[] := _kk_ids(st->'deck'); c int; m int[];
begin
  c := d[1];
  st := st || jsonb_build_object('deck', to_jsonb(d[2:]));
  m := array(select x from unnest(_kk_ids(st->'field')) x where x / 4 = c / 4 order by x);
  if cardinality(m) = 2 then
    return st || jsonb_build_object('phase', 'pick', 'drawn', c, 'opts', to_jsonb(m), 'win', (st->>'win')::int + 1);
  end if;
  st := _kk_put(st, s, c, null);
  st := (st - '_g') || jsonb_build_object('cur', (st->'cur') || jsonb_build_object('d', c, 'dg', st->'_g'));
  return _kk_after(st, s);
end $$;

-- 人・コンピューターの動き
--   play：{a: play, c: 手札, t: とる場の札（同じ月が2枚のとき）}
--   pick：{a: pick, t}（めくった札でとる札）。koi：{a: koi} / {a: stop}。end：{a: ready}（次の月へ）。timer：時間がきたら次の月
create or replace function public._kk_act(st jsonb, s int, mv jsonb) returns jsonb
language plpgsql volatile as $$
declare a text := mv->>'a'; ph text := st->>'phase'; c int; t int; h int[];
begin
  if coalesce((st->>'over')::boolean, false) then raise exception 'このゲームはもう終わっています'; end if;
  if a = 'timer' then
    if st->>'timer_at' is null or coalesce((st->>'now')::bigint, 0) < (st->>'timer_at')::bigint then return st; end if;
    if ph = 'end' then return _kk_next(st); end if;
    return st;
  end if;
  if ph = 'end' then
    if a <> 'ready' then raise exception '次の月を待っています'; end if;
    st := jsonb_set(st, array['ready', s::text], 'true');
    if (select coalesce(bool_and((st->'ready'->>(x::int))::boolean), true) from jsonb_array_elements_text(coalesce(st->'hum', '[]')) x) then
      return _kk_next(st);
    end if;
    return st;
  end if;
  if s <> (st->>'turn')::int then raise exception 'いまはあなたの番ではありません'; end if;
  if ph = 'play' then
    if a <> 'play' then raise exception '手札から1枚えらんで出してください'; end if;
    c := (mv->>'c')::int;
    h := _kk_ids(st->'hands'->s);
    if c is null or not (c = any(h)) then raise exception 'その札は持っていません'; end if;
    st := jsonb_set(st, array['hands', s::text], to_jsonb(array_remove(h, c)));
    st := _kk_put(st, s, c, (mv->>'t')::int);
    st := (st - '_g') || jsonb_build_object('cur', jsonb_build_object('p', c, 'pg', st->'_g'));
    return _kk_draw(st, s);
  end if;
  if ph = 'pick' then
    if a <> 'pick' then raise exception 'めくった札でとる札をえらんでください'; end if;
    t := (mv->>'t')::int;
    if t is null or not (t = any(_kk_ids(st->'opts'))) then raise exception 'その札はとれません'; end if;
    c := (st->>'drawn')::int;
    st := _kk_put(st, s, c, t);
    st := (st - '_g') || jsonb_build_object('cur', (st->'cur') || jsonb_build_object('d', c, 'dg', st->'_g'), 'phase', 'play', 'drawn', null, 'opts', null);
    return _kk_after(st, s);
  end if;
  if ph = 'koi' then
    if a = 'stop' then return _kk_win(st, s, false); end if;
    if a = 'koi' then
      st := st || jsonb_build_object('koi', jsonb_set(st->'koi', array[s::text], to_jsonb((st->'koi'->>s)::int + 1)),
                                     'yp', jsonb_set(st->'yp', array[s::text], to_jsonb(_kk_pts(_kk_yaku(_kk_ids(st->'took'->s))))));
      st := _kk_log(st, jsonb_build_object('a', 'koi', 's', s));
      return _kk_pass(st, s);
    end if;
    raise exception '「こいこい」か「勝負」をえらんでください';
  end if;
  raise exception 'その動きはできません';
end $$;

-- いま考える番の席
create or replace function public._kk_pending(st jsonb) returns int[]
language sql immutable as $$
  select case when coalesce((st->>'over')::boolean, false) or coalesce(st->>'phase', '') not in ('play', 'pick', 'koi') then '{}'::int[]
              else array[(st->>'turn')::int] end $$;

create or replace function public._kk_delay(st jsonb) returns int
language sql immutable as $$ select case when st->>'phase' = 'play' then 1300 else 1000 end $$;

-- コンピューター：札の値打ち・役のふえ方・あと何枚で役か（自分・相手）で、いちばんよい手
create or replace function public._kk_val(c int) returns numeric
language sql immutable as $$
  select (case when c = 40 then 12 when c in (0, 8, 28, 44) then 20 when c = 32 then 16 when c in (20, 24, 36) then 12
               when c in (1, 5, 9, 21, 33, 37) then 9 when c in (4, 12, 16, 29, 41) then 6 when c in (13, 17, 25, 42) then 4 else 1 end)::numeric $$;

create or replace function public._kk_need_set(tk int[], av int[], s int[]) returns int
language sql immutable as $$
  select case when s <@ tk then 99 else least(99, (select sum(case when x = any(tk) then 0 when x = any(av) then 1 else 99 end) from unnest(s) x))::int end $$;

-- あと何枚で点がふえるか（av：まだだれもとっていない札）。ふえようがなければ 99
create or replace function public._kk_need(tk int[], av int[]) returns int
language plpgsql immutable as $$
declare n int := 99; x int; lt int; lv int; rain boolean := 40 = any(tk); t int; r int; k int;
begin
  lt := (select count(*) from unnest(tk) c where c in (0, 8, 28, 40, 44));
  if lt < 5 then
    if lt - (case when rain then 1 else 0 end) >= 3 or lt >= 4 then x := 1;
      lv := (select count(*) from unnest(av) c where c in (0, 8, 28, 40, 44));
    elsif rain then x := 4 - lt; lv := (select count(*) from unnest(av) c where c in (0, 8, 28, 44));
    else x := 3 - lt; lv := (select count(*) from unnest(av) c where c in (0, 8, 28, 44));
    end if;
    if lv >= x then n := least(n, x); end if;
  end if;
  n := least(n, _kk_need_set(tk, av, array[8, 32]), _kk_need_set(tk, av, array[28, 32]), _kk_need_set(tk, av, array[20, 24, 36]),
             _kk_need_set(tk, av, array[1, 5, 9]), _kk_need_set(tk, av, array[21, 33, 37]));
  t := (select count(*) from unnest(tk) c where _kk_kind(c) = 'T'); x := greatest(5 - t, 1);
  if (select count(*) from unnest(av) c where _kk_kind(c) = 'T') >= x then n := least(n, x); end if;
  r := (select count(*) from unnest(tk) c where _kk_kind(c) = 'R'); x := greatest(5 - r, 1);
  if (select count(*) from unnest(av) c where _kk_kind(c) = 'R') >= x then n := least(n, x); end if;
  k := (select count(*) from unnest(tk) c where _kk_kind(c) = 'K' or c = 32); x := greatest(10 - k, 1);
  if (select count(*) from unnest(av) c where _kk_kind(c) = 'K' or c = 32) >= x then n := least(n, x); end if;
  return n;
end $$;

-- 札をとったときのよさ：値打ち・役のふえ方・自分の役に近づく・相手の役をじゃまする
create or replace function public._kk_gain(tk int[], ot int[], g int[]) returns numeric
language plpgsql immutable as $$
declare av0 int[]; av1 int[]; me0 int; me1 int; op0 int; op1 int;
begin
  av0 := array(select c from generate_series(0, 47) c where not (c = any(tk)) and not (c = any(ot)));
  av1 := array(select c from unnest(av0) c where not (c = any(g)));
  me0 := _kk_need(tk, av0); me1 := _kk_need(tk || g, av1);
  op0 := _kk_need(ot, av0); op1 := _kk_need(ot, av1);
  return coalesce((select sum(_kk_val(x)) from unnest(g) x), 0)
       + 10 * (_kk_pts(_kk_yaku(tk || g)) - _kk_pts(_kk_yaku(tk)))
       + 6 * coalesce((select sum(_kk_pts(_kk_yaku(ot || x)) - _kk_pts(_kk_yaku(ot))) from unnest(g) x), 0)
       + 3 * greatest(least(me0, 4) - least(me1, 4), 0)
       + 4 * greatest(least(op1, 4) - least(op0, 4), 0);
end $$;

create or replace function public._kk_cpu(st jsonb, s int) returns jsonb
language plpgsql volatile as $$
declare ph text := st->>'phase'; h int[] := _kk_ids(st->'hands'->s); f int[] := _kk_ids(st->'field');
        tk int[] := _kk_ids(st->'took'->s); ot int[] := _kk_ids(st->'took'->(1 - s)); c int; m int[]; t int; bc int; bt int;
        v numeric; bv numeric := -1e9; p int; gap int; seen int; av int[]; dme int; dop int;
begin
  if ph = 'koi' then
    p := _kk_pts(_kk_yaku(tk));
    gap := (st->'score'->>(1 - s))::int - (st->'score'->>s)::int;
    -- 相手がこいこいしている（いま上がれば2倍）・7点以上・手札が少ない → 勝負
    if (st->'koi'->>(1 - s))::int > 0 or p >= 7 or cardinality(h) <= 2 then return '{"a":"stop"}'; end if;
    av := array(select x from generate_series(0, 47) x where not (x = any(tk)) and not (x = any(ot)));
    dme := _kk_need(tk, av); dop := _kk_need(ot, av);
    -- 最後の月で、勝負しても追いつけないなら、こいこいして点をのばす
    if (st->>'mon')::int + 1 >= (st->>'months')::int and gap >= p and cardinality(h) >= 3 and dme <= 3 then return '{"a":"koi"}'; end if;
    if dop <= 1 then return '{"a":"stop"}'; end if;   -- 相手が役まであと1枚
    if dme <= 1 and dop >= 3 and cardinality(h) >= 3 then return '{"a":"koi"}'; end if;
    if dme <= 2 and dop >= 4 and cardinality(h) >= 5 and random() < 0.5 then return '{"a":"koi"}'; end if;
    return '{"a":"stop"}';
  end if;
  if ph = 'pick' then
    select x into t from unnest(_kk_ids(st->'opts')) x order by _kk_gain(tk, ot, array[(st->>'drawn')::int, x]) desc, x limit 1;
    return jsonb_build_object('a', 'pick', 't', t);
  end if;
  foreach c in array h loop
    m := array(select x from unnest(f) x where x / 4 = c / 4 order by x);
    t := null;
    if cardinality(m) = 0 then
      -- 場に置く：値打ちのある札は出したくない（同じ月がもう出つくしていれば平気。手にもう1枚あれば、あとでとり返せる）
      seen := (select count(*) from unnest(h || f || tk || ot) x where x / 4 = c / 4);
      v := -2 - _kk_val(c) * (case when seen >= 4 then 0 when (select count(*) from unnest(h) x where x / 4 = c / 4) >= 2 then 0.4 else 1 end);
    elsif cardinality(m) = 2 then
      select x into t from unnest(m) x order by _kk_gain(tk, ot, array[c, x]) desc, x limit 1;
      v := _kk_gain(tk, ot, array[c, t]);
    elsif cardinality(m) = 1 then
      t := m[1]; v := _kk_gain(tk, ot, array[c, t]);
    else
      v := _kk_gain(tk, ot, c || m);
    end if;
    v := v + random() * 0.8;
    if v > bv then bv := v; bc := c; bt := t; end if;
  end loop;
  return jsonb_build_object('a', 'play', 'c', bc, 't', bt);
end $$;

-- 見えるもの：自分の手札・場・山の枚数・とった札（ふたりとも見える）。月が終わったら、ふたりの手札
create or replace function public._kk_view(st jsonb, me int) returns jsonb
language plpgsql immutable as $$
declare over boolean := coalesce((st->>'over')::boolean, false); ph text := st->>'phase'; y0 jsonb; y1 jsonb;
begin
  y0 := _kk_yaku(_kk_ids(st->'took'->0)); y1 := _kk_yaku(_kk_ids(st->'took'->1));
  return jsonb_build_object('n', 2, 'months', st->'months', 'mon', st->'mon', 'oya', st->'oya', 'score', st->'score', 'turn', st->'turn', 'phase', ph,
    'field', st->'field', 'deck_n', jsonb_array_length(coalesce(st->'deck', '[]'::jsonb)),
    'counts', jsonb_build_array(jsonb_array_length(st->'hands'->0), jsonb_array_length(st->'hands'->1)),
    'hand', case when me is null or me not in (0, 1) then null else st->'hands'->me end,
    'hands', case when over or ph = 'end' then st->'hands' else null end,
    'took', st->'took', 'yaku', jsonb_build_array(y0, y1), 'pts', jsonb_build_array(_kk_pts(y0), _kk_pts(y1)),
    'koi', st->'koi', 'yp', st->'yp', 'drawn', st->'drawn', 'opts', st->'opts', 'cur', st->'cur', 'lt', st->'lt', 'log', st->'log', 'tn', st->'tn',
    'result', st->'result', 'ready', st->'ready', 'timer_at', st->'timer_at', 'hist', st->'hist', 'oyagime', st->'oyagime',
    'over', over, 'final', st->'final');
end $$;

-- みんなで遊ぶゲーム（ワンカード・麻雀・競り市・花札こいこい）
create or replace function public._is_multi(g text) returns boolean
language sql immutable as $$ select g in ('onecard', 'mahjong', 'auction', 'koikoi') $$;

create or replace function public._mg_init(g text, n int, opts jsonb) returns jsonb
language plpgsql volatile as $$
begin
  if g = 'onecard' then return _oc_init(n); end if;
  if g = 'mahjong' then return _mj_init(opts); end if;
  if g = 'auction' then return _au_init(n, opts); end if;
  if g = 'koikoi' then return _kk_init(opts); end if;
  raise exception 'そのゲームはまだ遊べません';
end $$;

-- いま考える番の席
create or replace function public._mg_pending(g text, st jsonb) returns int[]
language plpgsql immutable as $$
begin
  if g = 'onecard' then return _oc_pending(st); end if;
  if g = 'mahjong' then return _mj_pending(st); end if;
  if g = 'koikoi' then return _kk_pending(st); end if;
  return '{}';
end $$;

create or replace function public._mg_act(g text, st jsonb, s int, mv jsonb) returns jsonb
language plpgsql volatile as $$
begin
  if g = 'onecard' then return _oc_act(st, s, mv); end if;
  if g = 'mahjong' then return _mj_act(st, s, mv); end if;
  if g = 'auction' then return _au_act(st, s, mv); end if;
  if g = 'koikoi' then return _kk_act(st, s, mv); end if;
  raise exception 'そのゲームはまだ遊べません';
end $$;

create or replace function public._mg_cpu(g text, st jsonb, s int) returns jsonb
language plpgsql volatile as $$
begin
  if g = 'onecard' then return _oc_cpu(st, s); end if;
  if g = 'mahjong' then return _mj_cpu(st, s); end if;
  if g = 'koikoi' then return _kk_cpu(st, s); end if;
  raise exception 'そのゲームはまだ遊べません';
end $$;

create or replace function public._mg_view(g text, st jsonb, me int) returns jsonb
language plpgsql immutable as $$
begin
  if g = 'onecard' then return _oc_view(st, me); end if;
  if g = 'mahjong' then return _mj_view(st, me); end if;
  if g = 'auction' then return _au_view(st, me); end if;
  if g = 'koikoi' then return _kk_view(st, me); end if;
  return '{}';
end $$;

-- コンピューターが動くまでの間（ミリ秒）
create or replace function public._mg_delay(g text, st jsonb) returns int
language plpgsql immutable as $$
begin
  if g = 'mahjong' then return _mj_delay(st); end if;
  if g = 'koikoi' then return _kk_delay(st); end if;
  return 1100;
end $$;

-- いまの順位（rank：上から席、v：分けるときの点数、scale：賭け金ぶんの点数、ref：avg（人の平均とくらべる）/ best（人の1位とくらべる））
create or replace function public._mg_final(g text, st jsonb) returns jsonb
language plpgsql immutable as $$
begin
  if g = 'onecard' then return _oc_final(st); end if;
  if g = 'mahjong' then return _mj_final(st); end if;
  if g = 'auction' then return _au_final(st); end if;
  if g = 'koikoi' then return _kk_final(st); end if;
  return '{}';
end $$;

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

-- 預かっている賭け（観戦の賭け・賭け金）を返す
create or replace function public._room_refund(rid bigint) returns void
language plpgsql set search_path = public as $$
declare b record;
begin
  for b in select * from game_bets where room_id = rid and payout is null loop
    update profiles set balance = balance + b.amount where id = b.user_id;
    update game_bets set payout = b.amount where id = b.id;
    perform _log(b.user_id, 'game_bet', b.amount, b.amount, jsonb_build_object('room', rid, 'refund', true));
  end loop;
  for b in select * from game_stakes where room_id = rid and payout is null loop
    update profiles set balance = balance + b.amount where id = b.user_id;
    update game_stakes set payout = b.amount where room_id = rid and user_id = b.user_id;
    perform _log(b.user_id, 'game_stake', b.amount, b.amount, jsonb_build_object('room', rid, 'refund', true));
  end loop;
end $$;

-- 部屋をなくして、預かりを返す（only_waiting：まだ始まっていない部屋だけ）
drop function if exists public._room_cancel(bigint);
create or replace function public._room_cancel(rid bigint, only_waiting boolean default false) returns void
language plpgsql set search_path = public as $$
declare stt text;
begin
  select status into stt from game_rooms where id = rid for update;
  if stt is null or (only_waiting and stt <> 'waiting') then return; end if;
  if stt in ('waiting', 'playing') then update game_rooms set status = 'canceled', finished_at = _now() where id = rid; end if;
  perform _room_refund(rid);
end $$;

-- 賭け金をはらう（登録から7日・税の滞納なし）
create or replace function public._room_stake(r game_rooms, u uuid) returns void
language plpgsql set search_path = public as $$
declare made timestamptz;
begin
  if r.stake <= 0 then return; end if;
  select coalesce(ok7_at - interval '7 days', created_at) into made from profiles where id = u;
  if _now() < made + interval '7 days' then
    raise exception '賭けありの部屋は、登録から7日たってから入れます（%から）', _dlabel(made + interval '7 days');
  end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので、賭けありの部屋には入れません'; end if;
  perform _take(u, r.stake);
  insert into game_stakes(room_id, user_id, amount, at) values (r.id, u, r.stake, _now());
end $$;

-- いま人が打っている席（コンピューター・時間切れでない）
create or replace function public._mroom_hum(r game_rooms) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(i - 1 order by i), '[]'::jsonb) from generate_series(1, cardinality(r.seats)) i
   where r.seats[i] is not null and not ((i - 1) = any(r.auto)) $$;

-- 始める（人とコンピューターの席をランダムに）
create or replace function public._mroom_start(rid bigint, by_u uuid) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; s uuid[]; cs int[] := '{}'; n int; i int; st jsonb; b record; humans int;
begin
  select * into r from game_rooms where id = rid for update;
  n := r.max_seats;
  s := array(select x from unnest(r.seats || array_fill(null::uuid, array[n - cardinality(r.seats)])) x order by random());
  for i in 1..n loop if s[i] is null then cs := cs || (i - 1); end if; end loop;
  humans := n - cardinality(cs);
  if humans <= 1 then   -- 人がひとりなら賭けはなし（返す）
    for b in select * from game_stakes where room_id = rid loop
      update profiles set balance = balance + b.amount where id = b.user_id;
      perform _log(b.user_id, 'game_stake', b.amount, b.amount, jsonb_build_object('room', rid, 'refund', true));
    end loop;
    delete from game_stakes where room_id = rid;
  end if;
  st := _mg_init(r.game, n, r.opts);
  if r.game = 'auction' then st := _au_consign(rid, s, st); end if;   -- 釣った魚の出品
  r.seats := s; r.auto := '{}';
  st := st || jsonb_build_object('hum', _mroom_hum(r), 'cpus', to_jsonb(cs));
  update game_rooms set seats = s, cpu = cs, auto = '{}', status = 'playing', started_at = _now(), act_at = _now(), turn_at = _now(),
         wait_at = array_fill(_now(), array[n]), clock_ms = array_fill(r.time_ms, array[n]), move_no = 0, state = st,
         turn = coalesce((_mg_pending(r.game, st))[1], 0)
   where id = rid;
  for i in 1..n loop
    if s[i] is not null and s[i] <> by_u then
      perform _notice(s[i], format('【対戦】部屋 #%s（%s）が始まりました。遊戯タブの%sから入れます。', rid, _game_name(r.game), _game_name(r.game)));
    end if;
  end loop;
end $$;

-- 賭け金の精算
create or replace function public._mroom_settle(rid bigint) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; f jsonb; rk int[]; v numeric[]; scale numeric; hs int[] := '{}'; sk record; amt bigint; i int; s int;
        uid uuid; pot bigint; cut bigint; tcut bigint := 0; best int; ref numeric; raw numeric[]; loss bigint[]; gain bigint[];
        lsum bigint := 0; gsum numeric := 0; given bigint := 0; first_g int; n int; pay bigint;
begin
  select * into r from game_rooms where id = rid for update;
  if not found or r.status <> 'playing' then return; end if;
  f := coalesce(r.state->'final', _mg_final(r.game, r.state));
  rk := array(select jsonb_array_elements_text(f->'rank')::int);
  update game_rooms set status = 'finished', finished_at = _now(), reason = coalesce(r.state->>'why', '終わり'),
         winner = case when coalesce((f->>'draw')::boolean, false) then -1 else rk[1] end where id = rid;
  if not exists (select 1 from game_stakes where room_id = rid and payout is null) then return; end if;
  if coalesce((f->>'draw')::boolean, false) then perform _room_refund(rid); return; end if;   -- 引き分け：賭け金は返す
  n := cardinality(r.seats);
  amt := r.stake;
  -- 賭けている人の席（順位の順）
  foreach s in array rk loop
    if r.seats[s + 1] is not null and exists (select 1 from game_stakes where room_id = rid and user_id = r.seats[s + 1]) then hs := hs || s; end if;
  end loop;
  if cardinality(hs) <= 1 then perform _room_refund(rid); return; end if;
  loss := array_fill(0::bigint, array[n]); gain := array_fill(0::bigint, array[n]);
  if r.stake_mode = 'all' then
    pot := (select sum(amount) from game_stakes where room_id = rid);
    best := hs[1];
    loss := array_fill(amt, array[n]); loss[best + 1] := 0;
    gain[best + 1] := pot - amt;
  else
    v := array(select jsonb_array_elements_text(f->'v')::numeric);
    scale := (f->>'scale')::numeric;
    raw := array_fill(0::numeric, array[n]);
    if f->>'ref' = 'best' then
      best := hs[1];
      foreach s in array hs loop
        if s <> best then raw[s + 1] := amt * (v[s + 1] - v[best + 1]) / scale; end if;
      end loop;
      foreach s in array hs loop
        if s <> best then loss[s + 1] := least(amt, floor(-raw[s + 1]))::bigint; lsum := lsum + loss[s + 1]; end if;
      end loop;
      gain[best + 1] := lsum;
    else
      ref := (select avg(v[x + 1]) from unnest(hs) x);
      foreach s in array hs loop
        raw[s + 1] := amt * (v[s + 1] - ref) / scale;
        if raw[s + 1] < 0 then loss[s + 1] := least(amt, floor(-raw[s + 1]))::bigint; lsum := lsum + loss[s + 1];
        elsif raw[s + 1] > 0 then gsum := gsum + raw[s + 1]; end if;
      end loop;
      if gsum > 0 then
        foreach s in array hs loop
          if raw[s + 1] > 0 then
            gain[s + 1] := floor(lsum * raw[s + 1] / gsum)::bigint; given := given + gain[s + 1];
            if first_g is null then first_g := s; end if;
          end if;
        end loop;
        gain[first_g + 1] := gain[first_g + 1] + (lsum - given);   -- 端数は上の人に
      end if;
    end if;
  end if;
  foreach s in array hs loop
    uid := r.seats[s + 1];
    cut := floor(gain[s + 1] * 0.05);
    tcut := tcut + cut;
    pay := amt - loss[s + 1] + gain[s + 1] - cut;
    if pay > 0 then perform _give(uid, pay); end if;
    update game_stakes set payout = pay where room_id = rid and user_id = uid;
    perform _log(uid, 'game_stake', amt, pay, jsonb_build_object('room', rid, 'game', r.game, 'rank', array_position(rk, s)));
  end loop;
  if tcut > 0 then update treasury set balance = balance + tcut, casino_total = casino_total + tcut where id = 1; end if;
end $$;

-- 時間を進める：コンピューターの番・時間切れ・タイマー（古いできごとから順に）
--   人が全員いなくなったら（時間切れ・抜けた）、待たずにコンピューターだけで最後まで進める（budget：1回に進めるできごとの数）
drop function if exists public._mroom_tick(bigint);
create or replace function public._mroom_tick(rid bigint, budget int default 150) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; st jsonb; pend int[]; s int; ev timestamptz; best timestamptz; who int; kind text;
        n int := 0; nowt timestamptz := _now(); w0 text; p int; mv jsonb; fast boolean; lim int; st0 jsonb;
begin
  select * into r from game_rooms where id = rid for update;
  if not found or r.status <> 'playing' or not _is_multi(r.game) then return; end if;
  st := r.state;
  fast := jsonb_array_length(_mroom_hum(r)) = 0;
  lim := case when fast then budget else least(budget, 40) end;
  while n < lim and not coalesce((st->>'over')::boolean, false) loop
    pend := _mg_pending(r.game, st);
    best := null; who := null; kind := null;
    if st->>'timer_at' is not null then best := to_timestamp((st->>'timer_at')::numeric / 1000); kind := 'timer'; end if;
    foreach s in array pend loop
      if r.seats[s + 1] is null or s = any(r.auto) then
        ev := r.act_at + make_interval(secs => _mg_delay(r.game, st) / 1000.0);
        if best is null or ev < best then best := ev; who := s; kind := 'cpu'; end if;
      else
        ev := r.wait_at[s + 1] + make_interval(secs => r.clock_ms[s + 1] / 1000.0);
        if best is null or ev < best then best := ev; who := s; kind := 'timeout'; end if;
      end if;
    end loop;
    exit when best is null or (not fast and best > nowt);
    if best < r.act_at then best := r.act_at; end if;
    w0 := st->>'win';
    st := jsonb_set(st, '{now}', to_jsonb(_kb_ms(best)));
    st0 := st;
    if kind = 'timer' then
      st := _mg_act(r.game, st, -1, '{"a":"timer"}');
      if r.game = 'auction' then perform _au_money(rid, r.seats, st0, st); end if;
    elsif kind = 'timeout' then
      r.auto := r.auto || who; r.clock_ms[who + 1] := 0;
      st := st || jsonb_build_object('hum', _mroom_hum(r));
      fast := jsonb_array_length(_mroom_hum(r)) = 0;
      if fast then lim := greatest(lim, budget); end if;
    else
      mv := _mg_cpu(r.game, st, who);
      st := _mg_act(r.game, st, who, mv);
    end if;
    r.act_at := best;
    if st->>'win' is distinct from w0 then
      foreach p in array _mg_pending(r.game, st) loop r.wait_at[p + 1] := best; end loop;
    end if;
    n := n + 1;
  end loop;
  if n = 0 and not coalesce((st->>'over')::boolean, false) then return; end if;
  update game_rooms set state = st, auto = r.auto, clock_ms = r.clock_ms, act_at = r.act_at, wait_at = r.wait_at,
         turn = coalesce((_mg_pending(r.game, st))[1], turn), move_no = move_no + n where id = rid;
  if coalesce((st->>'over')::boolean, false) then perform _mroom_settle(rid); end if;
end $$;

-- 人が動く
create or replace function public._mroom_move(rid bigint, u uuid, mv jsonb) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; me int; st jsonb; nowt timestamptz := _now(); w0 text; p int; pend int[];
begin
  perform _mroom_tick(rid);
  select * into r from game_rooms where id = rid for update;
  if not found or r.status <> 'playing' then raise exception 'このゲームはもう終わっています'; end if;
  me := array_position(r.seats, u) - 1;
  if me is null then raise exception 'あなたは参加していません'; end if;
  if me = any(r.auto) then raise exception '時間切れ（または抜けた）なので、コンピューターが代わりに打っています'; end if;
  pend := _mg_pending(r.game, r.state);
  w0 := r.state->>'win';
  if r.game = 'auction' then perform _au_hold(u, mv); end if;
  st := _mg_act(r.game, jsonb_set(r.state, '{now}', to_jsonb(_kb_ms(nowt))), me, mv);
  if r.game = 'auction' then perform _au_money(rid, r.seats, r.state, st); end if;
  if me = any(pend) then
    r.clock_ms[me + 1] := greatest(r.clock_ms[me + 1] - floor(extract(epoch from (nowt - r.wait_at[me + 1])) * 1000)::int, 0);
    r.wait_at[me + 1] := nowt;
    r.act_at := nowt;
  end if;
  if st->>'win' is distinct from w0 then
    foreach p in array _mg_pending(r.game, st) loop r.wait_at[p + 1] := nowt; end loop;
    r.act_at := nowt;
  end if;
  update game_rooms set state = st, clock_ms = r.clock_ms, wait_at = r.wait_at, act_at = r.act_at,
         turn = coalesce((_mg_pending(r.game, st))[1], turn), move_no = move_no + 1 where id = rid;
  if coalesce((st->>'over')::boolean, false) then perform _mroom_settle(rid); end if;
end $$;

-- 持ち時間が切れていないか見る（ふたりのゲームは切れたら負け。4人までのゲームは、コンピューターが代わりに打つ）
drop function if exists public._room_tick(bigint);
create or replace function public._room_tick(rid bigint, budget int default 150) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; used int;
begin
  select * into r from game_rooms where id = rid;
  if not found or r.status <> 'playing' then return; end if;
  if _is_multi(r.game) then perform _mroom_tick(rid, budget); return; end if;
  if r.turn_at is null then return; end if;
  used := floor(extract(epoch from (_now() - r.turn_at)) * 1000);
  if used >= r.clock_ms[r.turn + 1] then
    update game_rooms set clock_ms[r.turn + 1] = 0 where id = rid;
    perform _room_finish(rid, 1 - r.turn, '時間切れ');
  end if;
end $$;

create or replace function public._room_json(r game_rooms, u uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare me int; used int := 0; clocks int[] := r.clock_ms; pend int[] := '{}'; run int[] := '{}'; sx int;
begin
  if _is_multi(r.game) then
    me := array_position(r.seats, u) - 1;
    if r.status = 'playing' then
      pend := _mg_pending(r.game, r.state);
      foreach sx in array pend loop
        if r.seats[sx + 1] is not null and not (sx = any(r.auto)) then
          run := run || sx;
          clocks[sx + 1] := greatest(clocks[sx + 1] - floor(extract(epoch from (_now() - r.wait_at[sx + 1])) * 1000)::int, 0);
        end if;
      end loop;
    end if;
    -- 麻雀は、自分の持ち時間だけ見える（ほかの人の時間がへると、鳴けるかどうかがわかってしまうので）
    if r.game = 'mahjong' then
      run := case when me is not null and me = any(run) then array[me] else '{}'::int[] end;
      clocks := array(select case when i - 1 = me then clocks[i] else -1 end from generate_series(1, cardinality(clocks)) i);
    end if;
    return jsonb_build_object('id', r.id, 'game', r.game, 'game_name', _game_name(r.game), 'title', r.title, 'status', r.status, 'multi', true,
      'host', (select nickname from profiles where id = r.host), 'host_badge', _badge(r.host), 'mine_host', r.host = u,
      'invites', (select coalesce(jsonb_agg(account_no), '[]'::jsonb) from profiles where id = any(r.invites)), 'invited_me', u = any(r.invites),
      'max_seats', r.max_seats, 'stake', r.stake, 'stake_mode', r.stake_mode, 'opts', r.opts,
      'players', (select coalesce(jsonb_agg(jsonb_build_object('seat', i - 1, 'nickname', coalesce(p.nickname, 'コンピューター'), 'uid', p.account_no,
                    'badge', case when p.id is null then null else _badge(p.id) end, 'cpu', r.seats[i] is null, 'auto', (i - 1) = any(r.auto)) order by i), '[]'::jsonb)
                  from generate_series(1, cardinality(r.seats)) i left join profiles p on p.id = r.seats[i]),
      'me', me, 'time_ms', r.time_ms, 'clock_ms', to_jsonb(clocks), 'running', to_jsonb(run),
      'turn', case when r.game = 'mahjong' then (r.state->>'turn')::int else r.turn end,
      'move_no', case when r.game = 'mahjong' then 0 else r.move_no end,
      'state', case when r.status in ('playing', 'finished') then _mg_view(r.game, r.state, me) else null end,
      'winner', r.winner, 'reason', r.reason, 'bets_on', false, 'bet_open', false, 'draw_offer', null, 'legal', '[]'::jsonb,
      'at', _dlabel(r.created_at));
  end if;
  me := case when r.seats[1] = u then 0 when r.seats[2] = u then 1 else null end;
  if r.status = 'playing' and r.turn_at is not null then
    used := floor(extract(epoch from (_now() - r.turn_at)) * 1000);
    clocks[r.turn + 1] := greatest(clocks[r.turn + 1] - used, 0);
  end if;
  return jsonb_build_object('id', r.id, 'game', r.game, 'game_name', _game_name(r.game), 'title', r.title, 'status', r.status, 'multi', false,
    'host', (select nickname from profiles where id = r.host), 'host_badge', _badge(r.host), 'mine_host', r.host = u,
    'invite', (select account_no from profiles where id = r.invite), 'invited_me', r.invite = u,
    'players', (select coalesce(jsonb_agg(jsonb_build_object('seat', s.n - 1, 'nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id)) order by s.n), '[]'::jsonb)
                  from unnest(r.seats) with ordinality s(uid, n) join profiles p on p.id = s.uid),
    'me', me, 'time_ms', r.time_ms, 'clock_ms', to_jsonb(clocks), 'running', case when r.status = 'playing' then jsonb_build_array(r.turn) else '[]'::jsonb end,
    'turn', r.turn, 'move_no', r.move_no,
    'state', r.state - 'rep' - 'legal', 'winner', r.winner, 'reason', r.reason, 'bets_on', r.bets_on, 'draw_offer', r.draw_offer,
    'bet_open', r.bets_on and r.status in ('waiting', 'playing') and r.move_no < 10,
    'legal', case when r.status = 'playing' and me = r.turn then _game_legal(r.game, r.state, me) else '[]'::jsonb end,
    'at', _dlabel(r.created_at));
end $$;

-- 部屋の一覧（えらんだゲーム。待っている部屋・対局中・自分の部屋）
create or replace function public.room_list(p_game text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r record;
begin
  if not _beta_ok(u, p_game) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  -- 1日たっても始まらない部屋は片づける（賭け金は返す）
  for r in select id from game_rooms where status = 'waiting' and created_at < _now() - interval '1 day' order by id for update skip locked loop
    perform _room_cancel(r.id, true);
  end loop;
  -- 長く止まっている部屋と自分の部屋を少しずつ進める（ほかの人が使っている部屋はとばす）
  for r in select id from game_rooms where status = 'playing' and game = p_game
              and (u = any(seats) or id in (select id from game_rooms where status = 'playing' and game = p_game order by coalesce(act_at, turn_at) nulls first limit 20))
            order by id for update skip locked loop
    begin
      perform _room_tick(r.id, 25);
    exception when others then null;   -- 1部屋のエラーで一覧を止めない
    end;
  end loop;
  return jsonb_build_object(
    'waiting', (select coalesce(jsonb_agg(_room_json(g, u) order by g.id desc), '[]'::jsonb) from (
                 select * from game_rooms where game = p_game and status = 'waiting'
                    and ((invite is null and cardinality(invites) = 0) or invite = u or u = any(invites) or host = u or u = any(seats))
                  order by id desc limit 30) g),
    'playing', (select coalesce(jsonb_agg(_room_json(g, u) || jsonb_build_object(
                   'pool', (select coalesce(sum(amount), 0) from game_bets where room_id = g.id)) order by g.id desc), '[]'::jsonb) from (
                 select * from game_rooms where game = p_game and status = 'playing' order by id desc limit 30) g),
    'finished', (select coalesce(jsonb_agg(_room_json(g, u) order by g.finished_at desc), '[]'::jsonb) from (
                 select * from game_rooms where game = p_game and status = 'finished' and u = any(seats) order by finished_at desc limit 10) g));
end $$;

-- 部屋を作る
--   ワンカード：p_seats 2〜4 人。麻雀：4人（p_opts の len：east 東風戦 / south 半荘戦）。花札こいこい：2人（p_opts の months：3・6・12か月）
--   p_stake：1人の賭け金（0は賭けなし）。p_mode：all（1位の総取り）/ points（点数で分ける）
drop function if exists public.room_create(text, text, int, text, boolean);
create or replace function public.room_create(p_game text, p_title text, p_time_min int, p_invite text, p_bets boolean,
                                              p_seats int default null, p_stake bigint default 0, p_mode text default 'all', p_opts jsonb default '{}')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); inv uuid; invs uuid[] := '{}'; rid bigint; n int := 2; x text; o jsonb := '{}'; r game_rooms;
begin
  if p_game not in ('reversi', 'chess', 'shogi', 'onecard', 'mahjong', 'auction', 'koikoi') then raise exception 'そのゲームはまだ遊べません'; end if;
  if not _beta_ok(u, p_game) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  if p_game = 'auction' and _is_guest(u) then raise exception '競り市はゲストでは遊べません（本登録すると遊べます）'; end if;
  if p_time_min is null or p_time_min < 1 or p_time_min > 180 then raise exception '持ち時間は1〜180分（3時間）です'; end if;
  if (select count(*) from game_rooms where host = u and status = 'waiting') >= 3 then raise exception '待っている部屋は3つまでです'; end if;
  if _is_multi(p_game) then
    n := case when p_game = 'mahjong' then 4 when p_game = 'koikoi' then 2 else coalesce(p_seats, 4) end;
    if p_game = 'auction' then
      if n not between 2 and 6 then raise exception '人数は2〜6人です'; end if;
    elsif n not between 2 and 4 then raise exception '人数は2〜4人です'; end if;
    if coalesce(p_stake, 0) < 0 or coalesce(p_stake, 0) > 10000000 then raise exception '賭け金は0〜1,000万 Xです'; end if;
    if coalesce(p_mode, 'all') not in ('all', 'points') then raise exception '分け方は「1位の総取り」か「点数で分ける」です'; end if;
    if p_game = 'mahjong' then
      o := jsonb_build_object('len', case when coalesce(p_opts->>'len', 'east') = 'south' then 'south' else 'east' end);
    end if;
    if p_game = 'koikoi' then
      o := jsonb_build_object('months', case when p_opts->>'months' in ('3', '6', '12') then (p_opts->>'months')::int else 6 end);
    end if;
    if p_game = 'auction' then   -- 競り市：賭け金はなし（落札した品でそのまま損得）
      o := jsonb_build_object('market', case when p_opts->>'market' in ('fish', 'antique', 'mix') then p_opts->>'market' else 'fish' end);
      p_stake := 0;
    end if;
    foreach x in array coalesce(regexp_split_to_array(btrim(coalesce(p_invite, '')), '[\s,、，]+'), '{}') loop
      continue when x = '';
      select id into inv from profiles where account_no = x;
      if inv is null then raise exception '招待する人のID（%）が見つかりません', x; end if;
      if inv = u then raise exception '自分は招待できません'; end if;
      if not (inv = any(invs)) then invs := invs || inv; end if;
    end loop;
    if cardinality(invs) > n - 1 then raise exception '招待できるのは%人までです', n - 1; end if;
    if (select count(*) from game_rooms where u = any(seats) and status in ('waiting', 'playing') and _is_multi(game)) >= 3 then
      raise exception 'ワンカード・麻雀・競り市・花札こいこいで参加中の部屋は3つまでです（終わってから作ってください）';
    end if;
    insert into game_rooms(game, title, host, invites, seats, time_ms, bets_on, max_seats, stake, stake_mode, opts, created_at)
    values (p_game, left(btrim(coalesce(p_title, '')), 30), u, invs, array[u], p_time_min * 60000, false, n, coalesce(p_stake, 0), coalesce(p_mode, 'all'), o, _now())
    returning * into r;
    perform _room_stake(r, u);
    foreach inv in array invs loop
      perform _notice(inv, format('【対戦】%s さんから%sに招待されました。遊戯タブの%sから入れます（部屋 #%s%s）。',
                      (select nickname from profiles where id = u), _game_name(p_game), _game_name(p_game), r.id,
                      case when r.stake > 0 then '・賭け金 ' || r.stake || ' X' else '' end));
    end loop;
    return room_state(r.id);
  end if;
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

-- 部屋に入る（ふたりのゲームは、そろったら始まる。4人までのゲームは、席がうまったら始まる）
create or replace function public.room_join(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; s uuid[];
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'waiting' then raise exception 'この部屋にはもう入れません'; end if;
  if not _beta_ok(u, r.game) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  if u = any(r.seats) then raise exception 'もう入っています'; end if;
  if _is_multi(r.game) then
    if cardinality(r.invites) > 0 and not (u = any(r.invites)) then raise exception 'この部屋は招待された人だけです'; end if;
    if cardinality(r.seats) >= r.max_seats then raise exception '席がいっぱいです'; end if;
    if r.game = 'auction' and _is_guest(u) then raise exception '競り市はゲストでは遊べません（本登録すると遊べます）'; end if;
    if (select count(*) from game_rooms where u = any(seats) and status in ('waiting', 'playing') and _is_multi(game)) >= 3 then
      raise exception 'ワンカード・麻雀・競り市・花札こいこいで参加中の部屋は3つまでです';
    end if;
    perform _room_stake(r, u);
    update game_rooms set seats = seats || u where id = r.id;
    perform _notice(r.host, format('【対戦】%s さんが部屋 #%s に入りました（%s/%s人）。', (select nickname from profiles where id = u), r.id,
                    cardinality(r.seats) + 1, r.max_seats));
    if cardinality(r.seats) + 1 >= r.max_seats then perform _mroom_start(r.id, u); end if;
    return room_state(r.id);
  end if;
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

-- 主催が始める（p_cpu：空いている席にコンピューターを入れる。false なら、いまいる人だけ＝ワンカードだけ）
create or replace function public.room_start(p_room bigint, p_cpu boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms;
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'waiting' or not _is_multi(r.game) then raise exception '始められる部屋が見つかりません'; end if;
  if r.host <> u then raise exception '始められるのは主催だけです'; end if;
  if not coalesce(p_cpu, false) then
    if r.game = 'mahjong' then raise exception '麻雀は4人で打ちます（足りない席はコンピューターが入ります）'; end if;
    if cardinality(r.seats) < 2 then raise exception 'ふたり以上いないと始められません（コンピューターを入れることもできます）'; end if;
    update game_rooms set max_seats = cardinality(r.seats) where id = r.id;
  end if;
  perform _mroom_start(r.id, u);
  return room_state(r.id);
end $$;

-- 部屋を出る（始まる前だけ。主催が出ると部屋はなくなる。賭けは返す）
create or replace function public.room_leave(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; amt bigint;
begin
  select * into r from game_rooms where id = p_room and status = 'waiting' and u = any(seats) for update;
  if not found then raise exception '出られる部屋が見つかりません（始まったあとは「投了」か「抜ける」）'; end if;
  if r.host = u then
    perform _room_cancel(r.id);
  else
    update game_rooms set seats = array_remove(seats, u) where id = r.id;
    delete from game_stakes where room_id = r.id and user_id = u returning amount into amt;
    if amt is not null then
      update profiles set balance = balance + amt where id = u;
      perform _log(u, 'game_stake', amt, amt, jsonb_build_object('room', r.id, 'refund', true));
    end if;
  end if;
  return room_list(r.game);
end $$;

-- 対局中に抜ける（そのあとはコンピューターが代わりに打つ。賭け金はそのまま）
create or replace function public.room_quit(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; me int;
begin
  perform _room_tick(p_room);
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'playing' or not _is_multi(r.game) then raise exception '抜けられるゲームが見つかりません'; end if;
  me := array_position(r.seats, u) - 1;
  if me is null then raise exception 'あなたは参加していません'; end if;
  if not (me = any(r.auto)) then
    r.auto := r.auto || me;
    update game_rooms set auto = r.auto, state = state || jsonb_build_object('hum', _mroom_hum(r)) where id = r.id;
  end if;
  perform _room_tick(r.id);
  return room_state(r.id);
end $$;

-- 部屋のようす（観戦もこれ）
create or replace function public.room_state(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms;
begin
  perform _room_tick(p_room);
  select * into r from game_rooms where id = p_room;
  if not found then raise exception '部屋が見つかりません'; end if;
  return _room_json(r, u) || jsonb_build_object(
    'moves', case when _is_multi(r.game) then '[]'::jsonb else
              (select coalesce(jsonb_agg(jsonb_build_object('n', n, 'seat', seat, 'move', move) order by n), '[]'::jsonb) from game_moves where room_id = r.id) end,
    'pool', (select coalesce(jsonb_agg(jsonb_build_object('seat', seat, 'amount', a, 'people', c) order by seat), '[]'::jsonb) from (
              select seat, sum(amount) a, count(distinct user_id) c from game_bets where room_id = r.id group by seat) z),
    'my_bets', (select coalesce(jsonb_agg(jsonb_build_object('seat', seat, 'amount', amount, 'payout', payout) order by id), '[]'::jsonb)
                  from game_bets where room_id = r.id and user_id = u),
    'stakes', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'seat', array_position(r.seats, k.user_id) - 1,
                  'amount', k.amount, 'payout', k.payout, 'me', k.user_id = u) order by k.at), '[]'::jsonb)
                 from game_stakes k join profiles p on p.id = k.user_id where k.room_id = r.id),
    'chat', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'body', z.body,
               'names', _mention_names(z.body), 'ts', _kb_ms(z.at), 'player', z.user_id = any(r.seats)) order by z.id), '[]'::jsonb) from (
              select * from game_chat where room_id = r.id order by id desc limit 40) z join profiles p on p.id = z.user_id),
    'now_ms', _kb_ms(_now()), 'balance', _bal(u));
end $$;

-- 手を指す・カードを出す・牌を打つ
create or replace function public.room_move(p_room bigint, p_move jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; me int; used int; ns jsonb; left_ms int;
begin
  if exists (select 1 from game_rooms where id = p_room and _is_multi(game)) then
    perform _mroom_move(p_room, u, p_move);
    return room_state(p_room);
  end if;
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
declare u uuid := _me_g(); r game_rooms; me int;
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'playing' then raise exception 'この対局はもう終わっています'; end if;
  if _is_multi(r.game) then raise exception 'このゲームに投了はありません（「抜ける」とコンピューターが代わりに打ちます）'; end if;
  me := case when r.seats[1] = u then 0 when r.seats[2] = u then 1 else null end;
  if me is null then raise exception 'あなたは対局していません'; end if;
  perform _room_finish(r.id, 1 - me, '投了');
  return room_state(r.id);
end $$;

-- 引き分けの申し出（offer）・受ける（accept）・断る／取り消す（decline）
create or replace function public.room_draw(p_room bigint, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; me int;
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status <> 'playing' then raise exception 'この対局はもう終わっています'; end if;
  if _is_multi(r.game) then raise exception 'このゲームでは引き分けの申し出はできません'; end if;
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

-- 観戦して賭ける（勝つと思う席に。登録から7日たってから）
create or replace function public.room_bet(p_room bigint, p_seat int, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; made timestamptz;
begin
  select * into r from game_rooms where id = p_room for update;
  if not found or r.status not in ('waiting', 'playing') then raise exception 'この対局にはもう賭けられません'; end if;
  if not r.bets_on or _is_multi(r.game) then raise exception 'この部屋は賭けなしです'; end if;
  if r.move_no >= 10 then raise exception '賭けは10手目までです'; end if;
  if u = any(r.seats) then raise exception '対局している本人は賭けられません'; end if;
  if r.status = 'waiting' then raise exception '対局が始まってから賭けられます（先手・後手が決まってから）'; end if;
  if p_seat not in (0, 1) then raise exception '賭ける側をえらんでください'; end if;
  if exists (select 1 from game_bets where room_id = r.id and user_id = u and seat <> p_seat) then raise exception '両方には賭けられません'; end if;
  if p_amount is null or p_amount < 1 then raise exception '1 X以上にしてください'; end if;
  select coalesce(ok7_at - interval '7 days', created_at) into made from profiles where id = u;
  if _now() < made + interval '7 days' then raise exception '観戦の賭けは、登録から7日たってからです（%から）', _dlabel(made + interval '7 days'); end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので賭けられません'; end if;
  perform _take(u, p_amount);
  insert into game_bets(room_id, user_id, seat, amount, at) values (r.id, u, p_seat, p_amount, _now());
  return room_state(r.id);
end $$;

-- チャット（10秒に1回・100文字まで）
create or replace function public.room_chat(p_room bigint, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); b text := btrim(coalesce(p_body, ''));
begin
  if not exists (select 1 from game_rooms where id = p_room) then raise exception '部屋が見つかりません'; end if;
  if char_length(b) < 1 then raise exception '何か書いてください'; end if;
  if char_length(b) > 100 then raise exception '100文字までです'; end if;
  if exists (select 1 from game_chat where user_id = u and at > _now() - interval '10 seconds') then raise exception '送るのは10秒に1回までです'; end if;
  insert into game_chat(room_id, user_id, body, at) values (p_room, u, b, _now());
  perform _mention_notify(u, b, format('部屋 #%s のチャット', p_room), jsonb_build_object('go', 'room', 'room', p_room));
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
declare u uuid := _me_g(); q text := btrim(coalesce(p_q, ''));
begin
  return (select coalesce(jsonb_agg(_pub_json(p, u) order by p.updated_at desc), '[]'::jsonb) from (
    select * from pubs p where p.kind = p_kind and (p.status = 'active' or (p.status <> 'deleted' and _pub_mine(p, u)))
       and (p.company_id is null or exists (select 1 from companies c where c.id = p.company_id and c.status in ('active', 'suspended')))
       and (q = '' or p.title ilike '%' || q || '%' or p.description ilike '%' || q || '%')
     order by p.updated_at desc limit 50) p);
end $$;

-- ニュース（新聞の無料の記事）
create or replace function public.news_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'title', z.title, 'pub_id', z.pub_id, 'paper', z.paper,
            'by', z.cname, 'official', z.official, 'ai', z.ai,
            'at', _dlabel(z.created_at), 'head', left(regexp_replace(z.body, '\s+', ' ', 'g'), 60)) order by z.id desc), '[]'::jsonb)
    from (select * from (select i.id, i.title, i.pub_id, p.title paper, c.name cname, c.official, c.ai, i.created_at, i.body
                           from pub_items i join pubs p on p.id = i.pub_id join companies c on c.id = p.company_id
                          where i.free and p.kind = 'paper' and p.status = 'active' and c.status in ('active', 'suspended') and not c.ai
                          order by i.id desc limit 150) h
          union all
          select * from (select i.id, i.title, i.pub_id, p.title paper, c.name cname, c.official, c.ai, i.created_at, i.body
                           from pub_items i join pubs p on p.id = i.pub_id join companies c on c.id = p.company_id
                          where i.free and p.kind = 'paper' and p.status = 'active' and c.status in ('active', 'suspended') and c.ai
                          order by i.id desc limit 150) m) z);
end $$;

-- 新聞・本のページ（記事・章の一覧）
create or replace function public.pub_page(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); p pubs; rd boolean;
begin
  select * into p from pubs where id = p_id;
  if not found or (p.status <> 'active' and not (_pub_mine(p, u) and p.status <> 'deleted') and not _is_staff(u)
                   and not exists (select 1 from pub_access a where a.pub_id = p.id and a.user_id = u and (a.until is null or a.until > _now()))) then
    raise exception '見つかりません';
  end if;
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
declare u uuid := _me_g(); i pub_items; p pubs;
begin
  select * into i from pub_items where id = p_item;
  if not found then raise exception '見つかりません'; end if;
  select * into p from pubs where id = i.pub_id;
  if p.status <> 'active' and not (_pub_mine(p, u) and p.status <> 'deleted') and not _is_staff(u)
     and not exists (select 1 from pub_access a where a.pub_id = p.id and a.user_id = u and (a.until is null or a.until > _now())) then
    raise exception '見つかりません';
  end if;
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
declare u uuid := _me(); p pubs; me profiles; fee bigint; tax bigint; c companies; cur timestamptz;
begin
  select * into p from pubs where id = p_id and status = 'active';
  if not found then raise exception '見つかりません'; end if;
  if _pub_mine(p, u) then raise exception '自分のものは買えません'; end if;
  if p.price = 0 then raise exception '無料なので、そのまま読めます'; end if;
  if p.kind = 'book' and exists (select 1 from pub_access where pub_id = p.id and user_id = u) then raise exception 'もう買っています'; end if;
  select * into me from profiles where id = u for update;
  if _now() < coalesce(me.ok7_at, me.created_at + interval '7 days') then raise exception '登録から7日たつまで、買い物はできません'; end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので買えません'; end if;
  if p.company_id is not null then
    select * into c from companies where id = p.company_id and status = 'active';
    if not found then raise exception 'この会社はいま営業していません'; end if;
  end if;
  fee := _xfer_fee(p.price);
  if me.balance < p.price + fee then raise exception 'AiliNaXが足りません（手数料 % X をふくめて % X 必要です）', fee, p.price + fee; end if;
  tax := _ctax(p.price);                          -- 消費税（値段にふくまれる。売る側に入る額から国庫へ）
  update profiles set balance = balance - (p.price + fee) where id = u;
  update treasury set balance = balance + fee + tax, fee_total = fee_total + fee, consumption_total = consumption_total + tax where id = 1;
  perform _log(u, 'pub_buy', p.price + fee, 0, jsonb_build_object('pub', p.id, 'title', p.title, 'tax', tax));
  if p.company_id is not null then
    perform _corp_move(p.company_id, p.price - tax, 'pub', format('「%s」の%s（%s さん・消費税 %s X をのぞく）', p.title,
                       case when p.kind = 'paper' then '購読料' else '売上' end, me.nickname, _fmt(tax)));
  else
    perform _give(p.author, p.price - tax);
    perform _log(p.author, 'pub_sale', 0, p.price - tax, jsonb_build_object('pub', p.id, 'title', p.title, 'tax', tax));
    perform _notice(p.author, format('【本】%s さんが「%s」を %s X で買いました（消費税 %s X をのぞいた %s X が入りました）。',
                                     me.nickname, p.title, _fmt(p.price), _fmt(tax), _fmt(p.price - tax)));
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
  if not found or not _pub_mine(p, u) or p.status = 'deleted' then raise exception '自分のものではありません（または削除ずみ）'; end if;
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
  if not found or not _pub_mine(p, u) or p.status = 'deleted' then raise exception '自分のものではありません（または削除ずみ）'; end if;
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
  if (not _pub_mine(p, u) or p.status = 'deleted') and not _is_staff(u) then raise exception '自分のものではありません（または削除ずみ）'; end if;
  delete from pub_items where id = i.id;
  return pub_page(p.id);
end $$;

-- 自分の本棚（買った本・購読中の新聞）と、書いているもの
create or replace function public.my_pubs() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return jsonb_build_object(
    'library', (select coalesce(jsonb_agg(_pub_json(p, u) order by p.updated_at desc), '[]'::jsonb)
                  from pubs p join pub_access a on a.pub_id = p.id and a.user_id = u where a.until is null or a.until > _now()),
    'mine', (select coalesce(jsonb_agg(_pub_json(p, u) order by p.updated_at desc), '[]'::jsonb) from pubs p where _pub_mine(p, u) and p.status <> 'deleted'),
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
  if not found or p.status = 'deleted' then raise exception '見つかりません（削除ずみ）'; end if;
  update pubs set status = case when p_hide then 'hidden' else 'active' end, reason = case when p_hide then left(coalesce(p_reason, ''), 200) end where id = p.id;
  owner_u := coalesce(p.author, (select owner from companies where id = p.company_id));
  perform _notice(owner_u, format('【広報・書籍】「%s」は管理者によって%s。%s', p.title, case when p_hide then '非公開になりました' else '公開にもどりました' end,
                  case when p_hide and coalesce(p_reason, '') <> '' then '理由：' || p_reason else '' end));
  return pub_page(p.id);
end $$;

-- ---------------------------------------------------------------------
-- 通知（ベル）
--   これまでのお知らせ（notices）に、開く場所（link）と、だれからか（from_user）を足した
--   一覧を開くと既読になる。新しい500件だけ残す
-- ---------------------------------------------------------------------
alter table public.notices add column if not exists link jsonb;
alter table public.notices add column if not exists from_user uuid references public.profiles(id) on delete set null;

create or replace function public._notice_l(u uuid, t text, lk jsonb, fu uuid) returns void
language sql set search_path = public as $$
  insert into notices(user_id, body, link, from_user) select u, t, lk, fu where not exists (select 1 from profiles where id = u and ai is not null) $$;

-- 通知の一覧（p_before より前を30件）。p_read = true なら、出したものを既読にする
create or replace function public.notice_list(p_before bigint, p_read boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); res jsonb; ids bigint[]; cut bigint;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'body', z.body, 'new', not z.seen, 'at', _dlabel(z.created_at),
           'time', to_char(z.created_at at time zone 'Asia/Tokyo', 'HH24:MI'), 'link', z.link,
           'from', (select jsonb_build_object('nickname', p.nickname, 'uid', p.account_no) from profiles p where p.id = z.from_user)) order by z.id desc), '[]'::jsonb),
         array_agg(z.id)
    into res, ids
    from (select * from notices where user_id = u and (p_before is null or id < p_before) order by id desc limit 30) z;
  if coalesce(p_read, false) and ids is not null then update notices set seen = true where user_id = u and id = any(ids) and not seen; end if;
  select id into cut from notices where user_id = u order by id desc offset 499 limit 1;
  if cut is not null then delete from notices where user_id = u and id < cut; end if;
  return jsonb_build_object('items', res, 'unread', (select count(*) from notices where user_id = u and not seen));
end $$;

-- 未読の数と、いちばん新しい通知（ベルの数字・この端末への通知に使う）
create or replace function public.notice_count() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); n record;
begin
  select id, body into n from notices where user_id = u order by id desc limit 1;
  return jsonb_build_object('unread', (select count(*) from notices where user_id = u and not seen), 'latest', n.id, 'latest_body', n.body,
    'msg', _msg_unread(u),
    'staff', case when _is_admin(u) then (select count(*) from support_threads t
                  where exists (select 1 from support_msgs m where m.thread_id = t.id and not m.from_staff and m.id > t.staff_seen)) end);
end $$;

create or replace function public.notice_read_all() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  update notices set seen = true where user_id = u and not seen;
  return jsonb_build_object('unread', 0);
end $$;

-- ---------------------------------------------------------------------
-- メンション：本文の「@ID（5けた）」。TLと対戦部屋のチャットで使える
-- ---------------------------------------------------------------------
create or replace function public._mention_ids(b text) returns text[]
language sql immutable as $$
  select coalesce(array(select distinct m[1] from regexp_matches(coalesce(b, ''), '@([0-9]{5,6})(?![0-9])', 'g') m), '{}') $$;

-- 本文に出てくる @ID → ニックネーム（表示用）
create or replace function public._mention_names(b text) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(p.account_no, p.nickname), '{}'::jsonb) from profiles p where p.account_no = any(_mention_ids(b)) $$;

-- メンションされた人に知らせる（自分はのぞく・5人まで）
create or replace function public._mention_notify(u uuid, b text, wher text, lk jsonb) returns void
language plpgsql set search_path = public as $$
declare me profiles; t uuid; ex text := regexp_replace(b, '\s+', ' ', 'g'); r record;
begin
  select * into me from profiles where id = u;
  for r in select key, value from jsonb_each_text(_mention_names(b)) loop ex := replace(ex, '@' || r.key, '@' || r.value); end loop;   -- @ID → @名前
  for t in select p.id from profiles p where p.account_no = any(_mention_ids(b)) and p.id <> u limit 5 loop
    perform _notice_l(t, format('【メンション】%s さんが%sであなたをメンションしました：「%s」', me.nickname, wher, left(ex, 60)), lk, u);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 人をさがす（ニックネームの一部かID）・人のページ
--   見えるのは、ニックネーム・ID・バッジ・社長をしている会社・書いた本・TLの投稿だけ（所持金などは見えない）
-- ---------------------------------------------------------------------
create or replace function public._person_card(p profiles, u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'me', p.id = u,
    'friend', (select case when f.status = 'ok' then 'ok' when f.from_user = u then 'out' else 'in' end from friends f
                where least(f.from_user, f.to_user) = least(u, p.id) and greatest(f.from_user, f.to_user) = greatest(u, p.id) limit 1)) $$;

create or replace function public.people_search(p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); q text := btrim(coalesce(p_q, '')); lk text;
begin
  if q = '' then   -- 何も入れないとき：フレンド
    return (select coalesce(jsonb_agg(_person_card(p, u) order by p.nickname), '[]'::jsonb) from (
              select * from profiles p where _is_friend(u, p.id) order by p.nickname limit 50) p);
  end if;
  q := ltrim(q, '@');
  lk := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return (select coalesce(jsonb_agg(_person_card(p, u) order by (p.account_no = q) desc, _is_friend(u, p.id) desc, p.nickname), '[]'::jsonb) from (
            select * from profiles p where (p.account_no = q or p.nickname ilike lk) and p.ai is null and not _is_guest(p.id)
             order by (p.account_no = q) desc, p.nickname limit 30) p);
end $$;

create or replace function public.person_page(p_uid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); p profiles;
begin
  select * into p from profiles where account_no = ltrim(btrim(coalesce(p_uid, '')), '@');
  if not found then raise exception 'その人は見つかりません'; end if;
  return _person_card(p, u) || jsonb_build_object(
    'since', to_char(p.created_at at time zone 'Asia/Tokyo', 'YYYY"年"FMMM"月"'),
    'rank', (select jsonb_build_object('lv', _gt_lv(coalesce(x.xp, 0)), 'title', _gt_title(_gt_lv(coalesce(x.xp, 0))),
               'titles', (select count(*) from gt_titles g where g.user_id = p.id),
               'best', (select z.name from _gt_titles() z join gt_titles g on g.lv = z.lv and g.user_id = p.id order by z.lv desc limit 1),
               'cr', _gt_tier(coalesce(_gt_cpts(c.pts, c.last_at), 0)), 'cr_name', _gt_tname(_gt_tier(coalesce(_gt_cpts(c.pts, c.last_at), 0))))
               from (select 1) one left join gt_xp x on x.user_id = p.id and x.month = _month_of(_now()) left join gt_casino c on c.user_id = p.id),
    'companies', (select coalesce(jsonb_agg(_corp_card(c, u) order by (c.status in ('active', 'suspended')) desc, c.id), '[]'::jsonb)
                    from companies c where c.owner = p.id and c.status in ('active', 'suspended', 'closed', 'bankrupt')),
    'books', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'price', x.price, 'kind', x.kind,
                'items', (select count(*) from pub_items where pub_id = x.id)) order by x.updated_at desc), '[]'::jsonb)
                from pubs x where x.author = p.id and x.status = 'active'),
    'posts', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'body', z.body, 'at', _dlabel(z.created_at), 'names', _mention_names(z.body)) order by z.id desc), '[]'::jsonb)
                from (select * from posts where user_id = p.id order by id desc limit 5) z));
end $$;

-- ---------------------------------------------------------------------
-- 新聞・本を消す
--   買った人・購読中の人がいなければ、記事・章ごと全部消す
--   いれば「削除済み」にして一覧から消す（買った人は本棚から読めるまま。購読は期間が終わるまで）
-- ---------------------------------------------------------------------
create or replace function public.pub_delete(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); p pubs;
begin
  select * into p from pubs where id = p_id for update;
  if not found or p.status = 'deleted' or not _pub_mine(p, u) then raise exception '消せるものが見つかりません'; end if;
  if exists (select 1 from pub_access where pub_id = p.id) then
    update pubs set status = 'deleted', updated_at = _now() where id = p.id;
  else
    delete from pubs where id = p.id;
  end if;
  return my_pubs();
end $$;

-- ---------------------------------------------------------------------
-- 企業の評価（週に1回・★1〜5）
--   その週（月〜日）に関わった会社を評価できる：買い物・口座・借入・勤め先・持ち株・新聞や本・請求・送金・取引所
--   1社以上評価すると、その週は国庫から 500 X（所得）。登録から7日たった人だけ。自分の会社は評価できない
--   会社の平均は「1人1社につき最新の評価」。評価が3人以上で、平均4.1以上は良企業・4.7以上は優良企業
-- ---------------------------------------------------------------------
create table if not exists public.review_rewards (
  user_id uuid not null references public.profiles(id) on delete cascade,
  week    date not null,
  amount  bigint not null,
  at      timestamptz not null default now(),
  primary key (user_id, week)
);
alter table public.review_rewards enable row level security;
revoke all on public.review_rewards from anon, authenticated;
alter table public.treasury add column if not exists review_total bigint not null default 0;
alter table public.corp_reviews enable row level security;
alter table public.review_rewards enable row level security;
revoke all on public.corp_reviews, public.review_rewards from anon, authenticated;


-- その週に関わった会社（company_id と、関わり方）
create or replace function public._corp_involved(u uuid) returns table(company_id int, how text)
language sql stable set search_path = public as $$
  with since as (select (_week_start(_now())::timestamp at time zone 'Asia/Tokyo') t),
  links as (
    select o.company_id, '買い物' how from corp_orders o, since where o.buyer = u and o.created_at >= since.t
    union all select b.company_id, '口座' from bank_accounts b where b.user_id = u and b.status = 'active'
    union all select l.company_id, '借入' from loans l, since where l.user_id = u and (l.status = 'active' or l.applied_at >= since.t)
    union all select m.company_id, '勤め先' from corp_members m where m.user_id = u
    union all select h.company_id, '株' from corp_holders h where h.user_id = u
    union all select x.company_id, case when x.kind = 'paper' then '新聞' else '本' end from pub_access a join pubs x on x.id = a.pub_id
               where a.user_id = u and x.company_id is not null and (a.until is null or a.until > _now())
    union all select coalesce(i.from_comp, i.to_comp), '請求' from invoices i, since
               where (i.from_user = u or i.to_user = u) and coalesce(i.from_comp, i.to_comp) is not null and coalesce(i.done_at, i.created_at) >= since.t
    union all select c.id, '送金' from tx_log t join companies c on c.cid = split_part(t.detail->>'id', '-', 1), since
               where t.user_id = u and t.game = 'send' and t.created_at >= since.t and coalesce(t.detail->>'id', '') <> ''
    union all select f.exch_id, '取引所' from fx_trades f, since where (f.buyer = u or f.seller = u) and f.exch_id is not null and f.created_at >= since.t)
  select l.company_id, string_agg(distinct l.how, '・') from links l join companies c on c.id = l.company_id
   where c.owner <> u and c.status in ('active', 'suspended')
   group by l.company_id $$;

create or replace function public.review_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); wk date := _week_start(_now()); made timestamptz;
begin
  select coalesce(ok7_at - interval '7 days', created_at) into made from profiles where id = u;
  return jsonb_build_object('week', to_char(wk, 'FMMM"月"FMDD"日"') || '〜' || to_char(wk + 6, 'FMMM"月"FMDD"日"'),
    'reward', 500, 'done', exists (select 1 from review_rewards where user_id = u and week = wk),
    'can', _now() >= made + interval '7 days', 'can_from', _dlabel(made + interval '7 days'),
    'list', (select coalesce(jsonb_agg(_corp_card(c, u) || jsonb_build_object('how', iv.how,
               'my', (select stars from corp_reviews r where r.company_id = c.id and r.user_id = u),
               'my_week', (select r.week = wk from corp_reviews r where r.company_id = c.id and r.user_id = u)) order by c.name), '[]'::jsonb)
             from _corp_involved(u) iv join companies c on c.id = iv.company_id),
    'balance', _bal(u));
end $$;

-- 評価を送る（p_ratings：[{cid, stars}]）。その週はじめての評価なら 500 X
create or replace function public.review_submit(p_ratings jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); wk date := _week_start(_now()); e jsonb; c companies; st int; n int := 0; made timestamptz; amt bigint := 500; tb bigint;
begin
  select coalesce(ok7_at - interval '7 days', created_at) into made from profiles where id = u for update;
  if _now() < made + interval '7 days' then raise exception '評価できるのは、登録から7日たってからです（%から）', _dlabel(made + interval '7 days'); end if;
  if jsonb_typeof(p_ratings) <> 'array' or jsonb_array_length(p_ratings) = 0 then raise exception '評価する会社をえらんでください'; end if;
  if jsonb_array_length(p_ratings) > 50 then raise exception '一度に評価できるのは50社までです'; end if;
  for e in select * from jsonb_array_elements(p_ratings) loop
    st := case when jsonb_typeof(e->'stars') = 'number' then (e->>'stars')::numeric::int end;
    if st is null or st not between 1 and 5 or (e->>'stars')::numeric <> st then raise exception '★は1〜5でえらんでください'; end if;
    select * into c from companies where cid = _cid_norm(e->>'cid');
    if not found or not exists (select 1 from _corp_involved(u) iv where iv.company_id = c.id) then
      raise exception '「%」は、今週関わった会社ではないので評価できません', coalesce(c.name, e->>'cid');
    end if;
    insert into corp_reviews(company_id, user_id, stars, week, updated_at) values (c.id, u, st, wk, _now())
    on conflict (company_id, user_id) do update set stars = excluded.stars, week = excluded.week, updated_at = excluded.updated_at;
    n := n + 1;
  end loop;
  if not exists (select 1 from review_rewards where user_id = u and week = wk) then
    select balance into tb from treasury where id = 1 for update;
    if tb >= amt then
      update treasury set balance = balance - amt, review_total = review_total + amt where id = 1;
      insert into review_rewards(user_id, week, amount, at) values (u, wk, amt, _now());
      perform _give(u, amt);
      perform _log(u, 'review', 0, amt, jsonb_build_object('week', wk, 'companies', n));
    end if;
  end if;
  return review_state();
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
-- 業種（日本標準産業分類・令和5年7月改定の中分類）
--   会社ごとに25まで。銀行は「62 銀行業」、証券は「65 金融商品取引業、商品先物取引業」を必ずふくむ（62・65 はその会社だけ）
--   「97 国家公務」「98 地方公務」は国営の会社だけ
-- ---------------------------------------------------------------------
create table if not exists public.industry_majors (
  major text primary key,        -- 大分類 A〜T
  name  text not null
);
create table if not exists public.industry_codes (
  code  text primary key,        -- 中分類 01〜99
  major text not null references public.industry_majors(major),
  name  text not null
);
alter table public.industry_majors enable row level security;
alter table public.industry_codes enable row level security;
revoke all on public.industry_majors, public.industry_codes from anon, authenticated;
insert into public.industry_majors(major, name) values
  ('A', '農業、林業'),
  ('B', '漁業'),
  ('C', '鉱業、採石業、砂利採取業'),
  ('D', '建設業'),
  ('E', '製造業'),
  ('F', '電気・ガス・熱供給・水道業'),
  ('G', '情報通信業'),
  ('H', '運輸業、郵便業'),
  ('I', '卸売業、小売業'),
  ('J', '金融業、保険業'),
  ('K', '不動産業、物品賃貸業'),
  ('L', '学術研究、専門・技術サービス業'),
  ('M', '宿泊業、飲食サービス業'),
  ('N', '生活関連サービス業、娯楽業'),
  ('O', '教育、学習支援業'),
  ('P', '医療、福祉'),
  ('Q', '複合サービス事業'),
  ('R', 'サービス業（他に分類されないもの）'),
  ('S', '公務（他に分類されるものを除く）'),
  ('T', '分類不能の産業')
on conflict (major) do update set name = excluded.name;
insert into public.industry_codes(code, major, name) values
  ('01', 'A', '農業'),
  ('02', 'A', '林業'),
  ('03', 'B', '漁業（水産養殖業を除く）'),
  ('04', 'B', '水産養殖業'),
  ('05', 'C', '鉱業、採石業、砂利採取業'),
  ('06', 'D', '総合工事業'),
  ('07', 'D', '職別工事業（設備工事業を除く）'),
  ('08', 'D', '設備工事業'),
  ('09', 'E', '食料品製造業'),
  ('10', 'E', '飲料・たばこ・飼料製造業'),
  ('11', 'E', '繊維工業'),
  ('12', 'E', '木材・木製品製造業（家具を除く）'),
  ('13', 'E', '家具・装備品製造業'),
  ('14', 'E', 'パルプ・紙・紙加工品製造業'),
  ('15', 'E', '印刷・同関連業'),
  ('16', 'E', '化学工業'),
  ('17', 'E', '石油製品・石炭製品製造業'),
  ('18', 'E', 'プラスチック製品製造業（別掲を除く）'),
  ('19', 'E', 'ゴム製品製造業'),
  ('20', 'E', 'なめし革・同製品・毛皮製造業'),
  ('21', 'E', '窯業・土石製品製造業'),
  ('22', 'E', '鉄鋼業'),
  ('23', 'E', '非鉄金属製造業'),
  ('24', 'E', '金属製品製造業'),
  ('25', 'E', 'はん用機械器具製造業'),
  ('26', 'E', '生産用機械器具製造業'),
  ('27', 'E', '業務用機械器具製造業'),
  ('28', 'E', '電子部品・デバイス・電子回路製造業'),
  ('29', 'E', '電気機械器具製造業'),
  ('30', 'E', '情報通信機械器具製造業'),
  ('31', 'E', '輸送用機械器具製造業'),
  ('32', 'E', 'その他の製造業'),
  ('33', 'F', '電気業'),
  ('34', 'F', 'ガス業'),
  ('35', 'F', '熱供給業'),
  ('36', 'F', '水道業'),
  ('37', 'G', '通信業'),
  ('38', 'G', '放送業'),
  ('39', 'G', '情報サービス業'),
  ('40', 'G', 'インターネット附随サービス業'),
  ('41', 'G', '映像・音声・文字情報制作業'),
  ('42', 'H', '鉄道業'),
  ('43', 'H', '道路旅客運送業'),
  ('44', 'H', '道路貨物運送業'),
  ('45', 'H', '水運業'),
  ('46', 'H', '航空運輸業'),
  ('47', 'H', '倉庫業'),
  ('48', 'H', '運輸に附帯するサービス業'),
  ('49', 'H', '郵便業（信書便事業を含む）'),
  ('50', 'I', '各種商品卸売業'),
  ('51', 'I', '繊維・衣服等卸売業'),
  ('52', 'I', '飲食料品卸売業'),
  ('53', 'I', '建築材料、鉱物・金属材料等卸売業'),
  ('54', 'I', '機械器具卸売業'),
  ('55', 'I', 'その他の卸売業'),
  ('56', 'I', '各種商品小売業'),
  ('57', 'I', '織物・衣服・身の回り品小売業'),
  ('58', 'I', '飲食料品小売業'),
  ('59', 'I', '機械器具小売業'),
  ('60', 'I', 'その他の小売業'),
  ('61', 'I', '無店舗小売業'),
  ('62', 'J', '銀行業'),
  ('63', 'J', '協同組織金融業'),
  ('64', 'J', '貸金業、クレジットカード業等非預金信用機関'),
  ('65', 'J', '金融商品取引業、商品先物取引業'),
  ('66', 'J', '補助的金融業等'),
  ('67', 'J', '保険業（保険媒介代理業、保険サービス業を含む）'),
  ('68', 'K', '不動産取引業'),
  ('69', 'K', '不動産賃貸業・管理業'),
  ('70', 'K', '物品賃貸業'),
  ('71', 'L', '学術・開発研究機関'),
  ('72', 'L', '専門サービス業（他に分類されないもの）'),
  ('73', 'L', '広告業'),
  ('74', 'L', '技術サービス業（他に分類されないもの）'),
  ('75', 'M', '宿泊業'),
  ('76', 'M', '飲食店'),
  ('77', 'M', '持ち帰り・配達飲食サービス業'),
  ('78', 'N', '洗濯・理容・美容・浴場業'),
  ('79', 'N', 'その他の生活関連サービス業'),
  ('80', 'N', '娯楽業'),
  ('81', 'O', '学校教育'),
  ('82', 'O', 'その他の教育、学習支援業'),
  ('83', 'P', '医療業'),
  ('84', 'P', '保健衛生'),
  ('85', 'P', '社会保険・社会福祉・介護事業'),
  ('86', 'Q', '郵便局'),
  ('87', 'Q', '協同組合（他に分類されないもの）'),
  ('88', 'R', '廃棄物処理業'),
  ('89', 'R', '自動車整備業'),
  ('90', 'R', '機械等修理業（別掲を除く）'),
  ('91', 'R', '職業紹介・労働者派遣業'),
  ('92', 'R', 'その他の事業サービス業'),
  ('93', 'R', '政治・経済・文化団体'),
  ('94', 'R', '宗教'),
  ('95', 'R', 'その他のサービス業'),
  ('96', 'R', '外国公務'),
  ('97', 'S', '国家公務'),
  ('98', 'S', '地方公務'),
  ('99', 'T', '分類不能の産業')
on conflict (code) do update set major = excluded.major, name = excluded.name;
-- 前からある銀行・証券会社には、その業種を入れておく
update public.companies set industries = '{62}' where kind = '銀行' and industries = '{}';
update public.companies set industries = '{65}' where kind = '証券' and industries = '{}';

-- 業種のコードをそろえる（重ならない・小さい順・25まで。銀行・証券は必ずふくむ）
create or replace function public._ind_norm(p text[], knd text, offi boolean) returns text[]
language plpgsql stable set search_path = public as $$
declare r text[]; x text; must text := case knd when '銀行' then '62' when '証券' then '65' end;
begin
  select coalesce(array_agg(distinct btrim(z)), '{}') into r from unnest(coalesce(p, '{}'::text[])) z where btrim(coalesce(z, '')) <> '';
  if must is not null and not (must = any(r)) then r := r || must; end if;
  select coalesce(array_agg(z order by z), '{}') into r from unnest(r) z;
  foreach x in array r loop
    if not exists (select 1 from industry_codes where code = x) then raise exception '業種「%」は日本標準産業分類（中分類）にありません', x; end if;
    if x in ('97', '98') and not coalesce(offi, false) then raise exception '「公務」は国営の会社だけがえらべます'; end if;
    if x = '62' and knd is distinct from '銀行' and not coalesce(offi, false) then raise exception '「銀行業」は銀行の会社だけがえらべます'; end if;
    if x = '65' and knd is distinct from '証券' and not coalesce(offi, false) then raise exception '「金融商品取引業、商品先物取引業」は証券の会社だけがえらべます'; end if;
  end loop;
  if cardinality(r) > 25 then raise exception '業種は25までです'; end if;
  return r;
end $$;

-- 社長：業種を変える
create or replace function public.corp_set_industries(p_cid text, p_inds text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; inds text[];
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('pending', 'active', 'suspended') then raise exception 'この会社はいま変えられません'; end if;
  inds := _ind_norm(p_inds, c.kind, c.official);
  if cardinality(inds) = 0 then raise exception '業種を1つ以上えらんでください'; end if;
  update companies set industries = inds where id = c.id;
  return my_corps();
end $$;

-- ---------------------------------------------------------------------
-- ゲーム・Discordのサーバー（どの会社でも5つまで）
--   kind：discord / minecraft / game（ほかのゲーム。ゲームの名前も書く）
--   link：Discordは招待リンクだけ。ほかは https のリンクか、サーバーのアドレス（例 play.example.jp:25565）
-- ---------------------------------------------------------------------
create or replace function public._srv_norm(p jsonb) returns jsonb
language plpgsql immutable as $$
declare r jsonb := '[]'::jsonb; e jsonb; k text; g text; nm text; lk text; nt text; i int := 0;
begin
  if p is null or jsonb_typeof(p) = 'null' then return '[]'::jsonb; end if;
  if jsonb_typeof(p) <> 'array' then raise exception 'サーバーの書き方がちがいます'; end if;
  if jsonb_array_length(p) > 5 then raise exception 'サーバーは5つまでです'; end if;
  for e in select x from jsonb_array_elements(p) x loop
    i := i + 1;
    if jsonb_typeof(e) <> 'object' then raise exception 'サーバーの書き方がちがいます'; end if;
    k := coalesce(e->>'kind', '');
    if k not in ('discord', 'minecraft', 'game') then raise exception '%つめ：種類（Discord・マイクラ・ほかのゲーム）をえらんでください', i; end if;
    g  := btrim(regexp_replace(coalesce(e->>'game', ''), '[[:cntrl:]]', ' ', 'g'));
    nm := btrim(regexp_replace(coalesce(e->>'name', ''), '[[:cntrl:]]', ' ', 'g'));
    lk := btrim(regexp_replace(coalesce(e->>'link', ''), '[[:cntrl:][:space:]]', '', 'g'));
    nt := btrim(regexp_replace(coalesce(e->>'note', ''), '[[:cntrl:]]', ' ', 'g'));
    if char_length(nm) < 1 or char_length(nm) > 40 then raise exception '%つめ：サーバー名は1〜40文字です', i; end if;
    if k = 'game' and (char_length(g) < 1 or char_length(g) > 30) then raise exception '%つめ：ゲームの名前を入れてください（30文字まで）', i; end if;
    if char_length(lk) > 200 then raise exception '%つめ：リンク・アドレスは200文字までです', i; end if;
    if char_length(nt) > 100 then raise exception '%つめ：ひとことは100文字までです', i; end if;
    if k = 'discord' and lk <> '' and lk !~* '^https://(discord\.gg|(www\.)?discord\.com/invite|discordapp\.com/invite)/[A-Za-z0-9-]{2,64}/?$' then
      raise exception '%つめ：Discordは招待リンク（https://discord.gg/… など）を入れてください', i;
    end if;
    if lk ~* '^(javascript|data|vbscript|file|about|blob):' then raise exception '%つめ：そのリンクは使えません', i; end if;
    if lk ~* '^http:' then raise exception '%つめ：リンクは https:// ではじまるものにしてください', i; end if;
    if lk ~* '^https:' and lk !~* '^https://[^/?#\s<>"''`]+([/?#][^\s<>"''`]*)?$' then raise exception '%つめ：リンクの形がちがいます', i; end if;
    if lk !~* '^https://' and lk <> '' and lk !~ '^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?$' then
      raise exception '%つめ：リンクは https:// ではじまるものか、サーバーのアドレス（例 play.example.jp:25565）にしてください', i;
    end if;
    r := r || jsonb_build_object('kind', k, 'game', case when k = 'game' then g else '' end, 'name', nm, 'link', lk, 'note', nt);
  end loop;
  return r;
end $$;

-- 社長：サーバーの一覧を保存する（全部まとめて書きかえ）
create or replace function public.corp_set_servers(p_cid text, p_servers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま変えられません'; end if;
  update companies set servers = _srv_norm(p_servers) where id = c.id;
  return my_corps();
end $$;

-- 管理者・副管理者：サーバー欄を消す（RMT のリンクなど）。社長に通知
create or replace function public.admin_corp_servers_clear(p_cid text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; why text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
begin
  if not _is_staff(u) then raise exception '管理者だけが使えます'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) for update;
  if not found then raise exception '会社が見つかりません'; end if;
  if c.servers = '[]'::jsonb then raise exception 'この会社のサーバー欄は空です'; end if;
  update companies set servers = '[]'::jsonb where id = c.id;
  perform _notice_l(c.owner, format('【サーバー】「%s」のゲーム・Discordのサーバー欄を、管理者が消しました。%s', c.name,
                    case when why is not null then '理由：' || why else '' end), jsonb_build_object('go', 'corp', 'cid', c.cid), u);
  return corp_page(c.cid);
end $$;

-- ---------------------------------------------------------------------
-- 連絡（メイン → 連絡）
--   メッセージ：フレンドどうしの1対1。ふたりだけが見られる。フレンドでなくなると送れない（前のものは読める）
--   問い合わせ：運営（管理者）への相談。本人と管理者だけが見られる。どちらからでも「解決済み」にできる
-- ---------------------------------------------------------------------
create table if not exists public.dm_threads (
  id         bigserial primary key,
  a          uuid not null references public.profiles(id) on delete cascade,     -- a < b
  b          uuid not null references public.profiles(id) on delete cascade,
  a_seen     bigint not null default 0,              -- a が読んだ最後のメッセージ
  b_seen     bigint not null default 0,
  last_at    timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (a < b),
  unique (a, b)
);
create index if not exists dm_threads_a_idx on public.dm_threads(a, last_at desc);
create index if not exists dm_threads_b_idx on public.dm_threads(b, last_at desc);
create table if not exists public.dm_msgs (
  id         bigserial primary key,
  thread_id  bigint not null references public.dm_threads(id) on delete cascade,
  author     uuid references public.profiles(id) on delete set null,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists dm_msgs_thread_idx on public.dm_msgs(thread_id, id);
create index if not exists dm_msgs_author_idx on public.dm_msgs(author, created_at);
create table if not exists public.support_threads (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  subject    text not null,
  status     text not null default 'open' check (status in ('open', 'closed')),
  closed_by  text,                                   -- user / staff
  user_seen  bigint not null default 0,
  staff_seen bigint not null default 0,
  last_at    timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists support_threads_user_idx on public.support_threads(user_id, last_at desc);
create index if not exists support_threads_last_idx on public.support_threads(last_at desc);
create table if not exists public.support_msgs (
  id         bigserial primary key,
  thread_id  bigint not null references public.support_threads(id) on delete cascade,
  from_staff boolean not null,
  author     uuid references public.profiles(id) on delete set null,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists support_msgs_thread_idx on public.support_msgs(thread_id, id);
create index if not exists support_msgs_author_idx on public.support_msgs(author, created_at);
alter table public.dm_threads enable row level security;
alter table public.dm_msgs enable row level security;
alter table public.support_threads enable row level security;
alter table public.support_msgs enable row level security;
revoke all on public.dm_threads, public.dm_msgs, public.support_threads, public.support_msgs from anon, authenticated;

-- 管理者のみなさん
create or replace function public._admin_ids() returns setof uuid
language sql stable set search_path = public as $$
  select btrim(x)::uuid from app_settings, unnest(string_to_array(value, ',')) x
   where key = 'admins' and btrim(x) ~ '^[0-9a-fA-F-]{36}$'
$$;

-- まだ読んでいない連絡の数（メッセージの相手の数＋運営から返事が来た問い合わせの数）
create or replace function public._msg_unread(u uuid) returns int
language sql stable set search_path = public as $$
  select ((select count(*) from dm_threads t where (t.a = u or t.b = u)
             and exists (select 1 from dm_msgs m where m.thread_id = t.id and m.author is distinct from u
                           and m.id > case when t.a = u then t.a_seen else t.b_seen end))
        + (select count(*) from support_threads t where t.user_id = u
             and exists (select 1 from support_msgs m where m.thread_id = t.id and m.from_staff and m.id > t.user_seen)))::int
$$;

-- メッセージの一覧（相手ごと）と、送れる相手（フレンド）
create or replace function public.dm_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return jsonb_build_object(
    'threads', (select coalesce(jsonb_agg(z.j order by z.last_at desc), '[]'::jsonb) from (
        select t.last_at, jsonb_build_object('uid', p.account_no, 'nickname', p.nickname, 'badge', _badge(p.id), 'friend', _is_friend(u, p.id),
          'unread', (select count(*) from dm_msgs m where m.thread_id = t.id and m.author is distinct from u
                       and m.id > case when t.a = u then t.a_seen else t.b_seen end),
          'last', (select left(m.body, 60) from dm_msgs m where m.thread_id = t.id order by m.id desc limit 1),
          'last_mine', (select m.author = u from dm_msgs m where m.thread_id = t.id order by m.id desc limit 1),
          'at', _dlabel(t.last_at), 'time', to_char(t.last_at at time zone 'Asia/Tokyo', 'HH24:MI')) j
          from dm_threads t join profiles p on p.id = case when t.a = u then t.b else t.a end
         where t.a = u or t.b = u order by t.last_at desc limit 100) z),
    'friends', (select coalesce(jsonb_agg(jsonb_build_object('uid', p.account_no, 'nickname', p.nickname, 'badge', _badge(p.id)) order by p.nickname), '[]'::jsonb)
                  from friends f join profiles p on p.id = case when f.from_user = u then f.to_user else f.from_user end
                 where f.status = 'ok' and (f.from_user = u or f.to_user = u)));
end $$;

-- 相手とのやりとり（新しい200通。開くと既読）
create or replace function public.dm_thread(p_uid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); pr profiles; t dm_threads; mx bigint;
begin
  select * into pr from profiles where account_no = btrim(coalesce(p_uid, '')) and ai is null;
  if not found or pr.id = u then raise exception '相手が見つかりません'; end if;
  select * into t from dm_threads where a = least(u, pr.id) and b = greatest(u, pr.id);
  if found then
    select max(id) into mx from dm_msgs where thread_id = t.id;
    if t.a = u and coalesce(mx, 0) > t.a_seen then update dm_threads set a_seen = mx where id = t.id;
    elsif t.b = u and coalesce(mx, 0) > t.b_seen then update dm_threads set b_seen = mx where id = t.id; end if;
  end if;
  return jsonb_build_object('uid', pr.account_no, 'nickname', pr.nickname, 'badge', _badge(pr.id), 'friend', _is_friend(u, pr.id),
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'mine', m.author = u, 'body', m.body,
               'at', _dlabel(m.created_at), 'time', to_char(m.created_at at time zone 'Asia/Tokyo', 'HH24:MI')) order by m.id), '[]'::jsonb)
             from (select * from dm_msgs where thread_id = t.id order by id desc limit 200) m));
end $$;

-- メッセージを送る（フレンドだけ。1000文字まで・1時間に120通まで）
create or replace function public.dm_send(p_uid text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); pr profiles; me profiles; t dm_threads; mid bigint; quiet boolean; bd text := btrim(coalesce(p_body, ''));
begin
  select * into pr from profiles where account_no = btrim(coalesce(p_uid, '')) and ai is null;
  if not found or pr.id = u then raise exception '相手が見つかりません'; end if;
  if not _is_friend(u, pr.id) then raise exception 'メッセージを送れるのはフレンドだけです'; end if;
  if char_length(bd) < 1 or char_length(bd) > 1000 then raise exception 'メッセージは1〜1000文字です'; end if;
  if (select count(*) from dm_msgs where author = u and created_at > _now() - interval '1 hour') >= 120 then
    raise exception '少し時間をおいてください（1時間に120通まで）';
  end if;
  insert into dm_threads(a, b, last_at, created_at) values (least(u, pr.id), greatest(u, pr.id), _now(), _now()) on conflict (a, b) do nothing;
  select * into t from dm_threads where a = least(u, pr.id) and b = greatest(u, pr.id) for update;
  -- 相手がまだ読んでいないメッセージがあれば、通知はもう届いているので送らない
  quiet := exists (select 1 from dm_msgs m where m.thread_id = t.id and m.author = u and m.id > case when t.a = pr.id then t.a_seen else t.b_seen end);
  insert into dm_msgs(thread_id, author, body, created_at) values (t.id, u, bd, _now()) returning id into mid;
  update dm_threads set last_at = _now(), a_seen = case when a = u then mid else a_seen end, b_seen = case when b = u then mid else b_seen end
   where id = t.id;
  if not quiet then
    select * into me from profiles where id = u;
    perform _notice_l(pr.id, format('【メッセージ】%s さん（ID %s）からメッセージが届きました', me.nickname, me.account_no),
                      jsonb_build_object('go', 'dm', 'u', me.account_no), u);
  end if;
  return dm_thread(pr.account_no);
end $$;

-- 問い合わせの一覧の1行（side = user：本人から見る／staff：管理者から見る）
create or replace function public._sp_json(t public.support_threads, side text) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', t.id, 'subject', t.subject, 'status', t.status, 'closed_by', t.closed_by,
    'user', case when side = 'staff' then jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id)) end,
    'unread', exists (select 1 from support_msgs m where m.thread_id = t.id and m.from_staff = (side = 'user')
                        and m.id > case when side = 'user' then t.user_seen else t.staff_seen end),
    'last', (select left(m.body, 60) from support_msgs m where m.thread_id = t.id order by m.id desc limit 1),
    'n', (select count(*) from support_msgs m where m.thread_id = t.id),
    'at', _dlabel(t.last_at), 'time', to_char(t.last_at at time zone 'Asia/Tokyo', 'HH24:MI'))
  from profiles p where p.id = t.user_id
$$;

-- 問い合わせの一覧（自分のもの。管理者には、みんなからの問い合わせも）
create or replace function public.support_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); adm boolean := _is_admin(u);
begin
  return jsonb_build_object('admin', adm,
    'threads', (select coalesce(jsonb_agg(_sp_json(t, 'user') order by (t.status = 'open') desc, t.last_at desc), '[]'::jsonb)
                  from (select * from support_threads where user_id = u order by (status = 'open') desc, last_at desc limit 50) t),
    'inbox', case when adm then (select coalesce(jsonb_agg(_sp_json(t, 'staff') order by (t.status = 'open') desc, t.last_at desc), '[]'::jsonb)
                  from (select * from support_threads order by (status = 'open') desc, last_at desc limit 100) t) end);
end $$;

-- 問い合わせのやりとり（開くと既読）
create or replace function public.support_thread(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); t support_threads; side text; mx bigint;
begin
  select * into t from support_threads where id = p_id;
  if not found then raise exception '問い合わせが見つかりません'; end if;
  side := case when t.user_id = u then 'user' when _is_admin(u) then 'staff' end;
  if side is null then raise exception '問い合わせが見つかりません'; end if;
  select max(id) into mx from support_msgs where thread_id = t.id;
  if side = 'user' and coalesce(mx, 0) > t.user_seen then update support_threads set user_seen = mx where id = t.id;
  elsif side = 'staff' and coalesce(mx, 0) > t.staff_seen then update support_threads set staff_seen = mx where id = t.id; end if;
  select * into t from support_threads where id = p_id;
  return _sp_json(t, side) || jsonb_build_object('side', side, 'can_send', t.status = 'open',
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'staff', m.from_staff, 'body', m.body,
               'who', case when side = 'staff' and m.from_staff then (select nickname from profiles where id = m.author) end,
               'mine', m.author = u, 'at', _dlabel(m.created_at), 'time', to_char(m.created_at at time zone 'Asia/Tokyo', 'HH24:MI')) order by m.id), '[]'::jsonb)
             from support_msgs m where m.thread_id = t.id));
end $$;

-- 問い合わせる（受付中は3件まで・新しいものは1日5件まで）
create or replace function public.support_open(p_subject text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); me profiles; tid bigint; mid bigint; who uuid;
  sj text := btrim(regexp_replace(coalesce(p_subject, ''), '[[:cntrl:]]', ' ', 'g')); bd text := btrim(coalesce(p_body, ''));
begin
  if char_length(sj) < 1 or char_length(sj) > 40 then raise exception '件名は1〜40文字です'; end if;
  if char_length(bd) < 1 or char_length(bd) > 2000 then raise exception '内容は1〜2000文字です'; end if;
  perform pg_advisory_xact_lock(7310, hashtext(u::text));
  if (select count(*) from support_threads where user_id = u and status = 'open') >= 3 then
    raise exception '受付中の問い合わせは3件までです（解決済みにすると、新しく問い合わせられます）';
  end if;
  if (select count(*) from support_threads where user_id = u and created_at > _now() - interval '1 day') >= 5 then
    raise exception '新しい問い合わせは1日5件までです';
  end if;
  select * into me from profiles where id = u;
  insert into support_threads(user_id, subject, last_at, created_at) values (u, sj, _now(), _now()) returning id into tid;
  insert into support_msgs(thread_id, from_staff, author, body, created_at) values (tid, false, u, bd, _now()) returning id into mid;
  update support_threads set user_seen = mid where id = tid;
  for who in select * from _admin_ids() loop
    continue when who = u;
    perform _notice_l(who, format('【問い合わせ】%s さん（ID %s）から問い合わせが届きました：%s', me.nickname, me.account_no, sj),
                      jsonb_build_object('go', 'sp', 't', tid), u);
  end loop;
  return support_thread(tid);
end $$;

-- 返事を書く（本人も管理者も）
create or replace function public.support_send(p_id bigint, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t support_threads; side text; me profiles; mid bigint; who uuid; quiet boolean; bd text := btrim(coalesce(p_body, ''));
begin
  select * into t from support_threads where id = p_id for update;
  if not found then raise exception '問い合わせが見つかりません'; end if;
  side := case when t.user_id = u then 'user' when _is_admin(u) then 'staff' end;
  if side is null then raise exception '問い合わせが見つかりません'; end if;
  if t.status <> 'open' then raise exception 'この問い合わせは解決済みです（つづきは新しく問い合わせてください）'; end if;
  if char_length(bd) < 1 or char_length(bd) > 2000 then raise exception '内容は1〜2000文字です'; end if;
  if (select count(*) from support_msgs where thread_id = t.id) >= 300 then raise exception 'この問い合わせはやりとりが多くなりました（つづきは新しく問い合わせてください）'; end if;
  if (select count(*) from support_msgs where author = u and created_at > _now() - interval '1 hour') >= 60 then
    raise exception '少し時間をおいてください（1時間に60通まで）';
  end if;
  quiet := exists (select 1 from support_msgs m where m.thread_id = t.id and m.from_staff = (side = 'staff')
                     and m.id > case when side = 'staff' then t.user_seen else t.staff_seen end);
  insert into support_msgs(thread_id, from_staff, author, body, created_at) values (t.id, side = 'staff', u, bd, _now()) returning id into mid;
  update support_threads set last_at = _now(),
         user_seen = case when side = 'user' then mid else user_seen end,
         staff_seen = case when side = 'staff' then mid else staff_seen end
   where id = t.id;
  if quiet then
    null;
  elsif side = 'staff' then
    perform _notice_l(t.user_id, format('【問い合わせ】運営から返事が届きました：%s', t.subject), jsonb_build_object('go', 'sp', 't', t.id), null);
  else
    select * into me from profiles where id = u;
    for who in select * from _admin_ids() loop
      continue when who = u;
      perform _notice_l(who, format('【問い合わせ】%s さんから、問い合わせ「%s」に返事が届きました', me.nickname, t.subject), jsonb_build_object('go', 'sp', 't', t.id), u);
    end loop;
  end if;
  return support_thread(t.id);
end $$;

-- 解決済みにする（どちらからでも）
create or replace function public.support_close(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t support_threads; side text;
begin
  select * into t from support_threads where id = p_id for update;
  if not found then raise exception '問い合わせが見つかりません'; end if;
  side := case when t.user_id = u then 'user' when _is_admin(u) then 'staff' end;
  if side is null then raise exception '問い合わせが見つかりません'; end if;
  if t.status <> 'open' then raise exception 'この問い合わせはもう解決済みです'; end if;
  update support_threads set status = 'closed', closed_by = side where id = t.id;
  if side = 'staff' then
    perform _notice_l(t.user_id, format('【問い合わせ】問い合わせ「%s」は、運営が解決済みにしました', t.subject), jsonb_build_object('go', 'sp', 't', t.id), null);
  end if;
  return support_thread(t.id);
end $$;

-- ---------------------------------------------------------------------
-- 窓口（会社への相談）
--   だれでも会社に相談できる（件名と内容）。会社は社長と「窓口担当」の社員が返事する
--   相談した人と会社だけが見られる。どちらからでも「解決済み」にできる（そのあとは読むだけ）
--   受付中の相談は1社に3件まで。新しい相談は1日10件まで
-- ---------------------------------------------------------------------
alter table public.corp_members add column if not exists desk boolean not null default false;   -- 窓口担当
create table if not exists public.desk_threads (
  id         bigserial primary key,
  company_id int not null references public.companies(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  subject    text not null,
  status     text not null default 'open' check (status in ('open', 'closed')),
  closed_by  text,                                   -- user / corp
  user_seen  bigint not null default 0,              -- 相談した人が読んだ最後のメッセージ
  corp_seen  bigint not null default 0,              -- 会社が読んだ最後のメッセージ
  last_at    timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists desk_threads_corp_idx on public.desk_threads(company_id, last_at desc);
create index if not exists desk_threads_user_idx on public.desk_threads(user_id, last_at desc);
create table if not exists public.desk_msgs (
  id         bigserial primary key,
  thread_id  bigint not null references public.desk_threads(id) on delete cascade,
  from_corp  boolean not null,
  author     uuid references public.profiles(id) on delete set null,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists desk_msgs_thread_idx on public.desk_msgs(thread_id, id);
create index if not exists desk_msgs_author_idx on public.desk_msgs(author, created_at);
alter table public.desk_threads enable row level security;
alter table public.desk_msgs enable row level security;
revoke all on public.desk_threads, public.desk_msgs from anon, authenticated;

-- 会社の窓口の人（社長か窓口担当の社員）
create or replace function public._desk_staff(cid_int int, u uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from companies where id = cid_int and owner = u)
      or exists (select 1 from corp_members where company_id = cid_int and user_id = u and desk)
$$;

-- 相談の一覧の1行（side = user：相談した人から見る／corp：会社から見る）
create or replace function public._desk_json(t public.desk_threads, side text) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', t.id, 'subject', t.subject, 'status', t.status, 'closed_by', t.closed_by,
    'company', c.name, 'cid', c.cid, 'corp_status', c.status,
    'user', case when side = 'corp' then jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id)) end,
    'unread', exists (select 1 from desk_msgs m where m.thread_id = t.id and m.from_corp = (side = 'user')
                         and m.id > case when side = 'user' then t.user_seen else t.corp_seen end),
    'last', (select left(m.body, 60) from desk_msgs m where m.thread_id = t.id order by m.id desc limit 1),
    'last_corp', (select m.from_corp from desk_msgs m where m.thread_id = t.id order by m.id desc limit 1),
    'n', (select count(*) from desk_msgs m where m.thread_id = t.id),
    'at', _dlabel(t.last_at), 'time', to_char(t.last_at at time zone 'Asia/Tokyo', 'HH24:MI'))
  from companies c, profiles p where c.id = t.company_id and p.id = t.user_id
$$;

-- 会社の窓口の人たち（通知を送る相手）
create or replace function public._desk_people(cid_int int) returns setof uuid
language sql stable set search_path = public as $$
  select owner from companies where id = cid_int
  union
  select user_id from corp_members where company_id = cid_int and desk
$$;

-- 相談のやりとり（開くと既読になる）
create or replace function public.desk_thread(p_thread bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t desk_threads; side text; c companies; mx bigint;
begin
  select * into t from desk_threads where id = p_thread;
  if not found then raise exception '相談が見つかりません'; end if;
  side := case when t.user_id = u then 'user' when _desk_staff(t.company_id, u) then 'corp' end;
  if side is null then raise exception '相談が見つかりません'; end if;
  select * into c from companies where id = t.company_id;
  select max(id) into mx from desk_msgs where thread_id = t.id;
  if side = 'user' and coalesce(mx, 0) > t.user_seen then update desk_threads set user_seen = mx where id = t.id;
  elsif side = 'corp' and coalesce(mx, 0) > t.corp_seen then update desk_threads set corp_seen = mx where id = t.id; end if;
  select * into t from desk_threads where id = p_thread;
  return _desk_json(t, side) || jsonb_build_object('side', side,
    'can_send', t.status = 'open' and c.status in ('active', 'suspended'),
    'desk_note', c.desk_note,
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'corp', m.from_corp, 'body', m.body,
               'who', case when m.from_corp then (select nickname from profiles where id = m.author) end,
               'mine', m.author = u, 'at', _dlabel(m.created_at), 'time', to_char(m.created_at at time zone 'Asia/Tokyo', 'HH24:MI')) order by m.id), '[]'::jsonb)
             from desk_msgs m where m.thread_id = t.id));
end $$;

-- 相談する（新しい相談）
create or replace function public.desk_open(p_cid text, p_subject text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; me profiles; tid bigint; mid bigint; who uuid;
  sj text := btrim(regexp_replace(coalesce(p_subject, ''), '[[:cntrl:]]', ' ', 'g'));
  bd text := btrim(coalesce(p_body, ''));
begin
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません（廃業・倒産した会社には相談できません）'; end if;
  if not c.desk_on then raise exception 'この会社はいま窓口の相談を受け付けていません'; end if;
  if _desk_staff(c.id, u) then raise exception '自分の会社（担当している窓口）には相談できません'; end if;
  if char_length(sj) < 1 or char_length(sj) > 40 then raise exception '件名は1〜40文字です'; end if;
  if char_length(bd) < 1 or char_length(bd) > 1000 then raise exception '内容は1〜1000文字です'; end if;
  perform pg_advisory_xact_lock(7300, hashtext(u::text));
  if (select count(*) from desk_threads where company_id = c.id and user_id = u and status = 'open') >= 3 then
    raise exception 'この会社への相談は、受付中のものが3件までです（解決済みにすると、新しく相談できます）';
  end if;
  if (select count(*) from desk_threads where user_id = u and created_at > _now() - interval '1 day') >= 10 then
    raise exception '新しい相談は1日10件までです';
  end if;
  select * into me from profiles where id = u;
  insert into desk_threads(company_id, user_id, subject, last_at, created_at) values (c.id, u, sj, _now(), _now()) returning id into tid;
  insert into desk_msgs(thread_id, from_corp, author, body, created_at) values (tid, false, u, bd, _now()) returning id into mid;
  update desk_threads set user_seen = mid where id = tid;
  for who in select * from _desk_people(c.id) loop
    perform _notice_l(who, format('【窓口】%s さん（ID %s）から「%s」に相談が届きました：%s', me.nickname, me.account_no, c.name, sj),
                      jsonb_build_object('go', 'desk', 't', tid), u);
  end loop;
  return desk_thread(tid);
end $$;

-- 返事を書く（相談した人も会社も）
create or replace function public.desk_send(p_thread bigint, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t desk_threads; side text; c companies; me profiles; mid bigint; who uuid; quiet boolean;
  bd text := btrim(coalesce(p_body, ''));
begin
  select * into t from desk_threads where id = p_thread for update;
  if not found then raise exception '相談が見つかりません'; end if;
  side := case when t.user_id = u then 'user' when _desk_staff(t.company_id, u) then 'corp' end;
  if side is null then raise exception '相談が見つかりません'; end if;
  select * into c from companies where id = t.company_id;
  if t.status <> 'open' then raise exception 'この相談は解決済みです（つづきは新しく相談してください）'; end if;
  if c.status not in ('active', 'suspended') then raise exception 'この会社はもう活動していません'; end if;
  if char_length(bd) < 1 or char_length(bd) > 1000 then raise exception '内容は1〜1000文字です'; end if;
  if (select count(*) from desk_msgs where thread_id = t.id) >= 300 then raise exception 'この相談はやりとりが多くなりました（つづきは新しく相談してください）'; end if;
  if (select count(*) from desk_msgs where author = u and created_at > _now() - interval '1 hour') >= 60 then
    raise exception '少し時間をおいてください（1時間に60通まで）';
  end if;
  -- 相手がまだ読んでいないものがあれば、通知はもう届いているので送らない
  quiet := exists (select 1 from desk_msgs m where m.thread_id = t.id and m.from_corp = (side = 'corp')
                     and m.id > case when side = 'corp' then t.user_seen else t.corp_seen end);
  insert into desk_msgs(thread_id, from_corp, author, body, created_at) values (t.id, side = 'corp', u, bd, _now()) returning id into mid;
  update desk_threads set last_at = _now(),
         user_seen = case when side = 'user' then mid else user_seen end,
         corp_seen = case when side = 'corp' then mid else corp_seen end
   where id = t.id;
  if quiet then
    null;
  elsif side = 'corp' then
    perform _notice_l(t.user_id, format('【窓口】「%s」から返事が届きました：%s', c.name, t.subject), jsonb_build_object('go', 'desk', 't', t.id), null);
  else
    select * into me from profiles where id = u;
    for who in select * from _desk_people(c.id) loop
      perform _notice_l(who, format('【窓口】%s さんから「%s」への相談に返事が届きました：%s', me.nickname, c.name, t.subject),
                        jsonb_build_object('go', 'desk', 't', t.id), u);
    end loop;
  end if;
  return desk_thread(t.id);
end $$;

-- 解決済みにする（どちらからでも）
create or replace function public.desk_close(p_thread bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); t desk_threads; side text; c companies; who uuid;
begin
  select * into t from desk_threads where id = p_thread for update;
  if not found then raise exception '相談が見つかりません'; end if;
  side := case when t.user_id = u then 'user' when _desk_staff(t.company_id, u) then 'corp' end;
  if side is null then raise exception '相談が見つかりません'; end if;
  if t.status <> 'open' then raise exception 'この相談はもう解決済みです'; end if;
  select * into c from companies where id = t.company_id;
  update desk_threads set status = 'closed', closed_by = side where id = t.id;
  if side = 'corp' then
    perform _notice_l(t.user_id, format('【窓口】「%s」への相談「%s」は、会社が解決済みにしました', c.name, t.subject), jsonb_build_object('go', 'desk', 't', t.id), null);
  else
    for who in select * from _desk_people(c.id) loop
      perform _notice_l(who, format('【窓口】「%s」への相談「%s」は、相談した人が解決済みにしました', c.name, t.subject), jsonb_build_object('go', 'desk', 't', t.id), u);
    end loop;
  end if;
  return desk_thread(t.id);
end $$;

-- 相談の一覧（p_cid が空なら自分が出した相談、会社のIDなら会社の窓口）
create or replace function public.desk_list(p_cid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); c companies;
begin
  if btrim(coalesce(p_cid, '')) = '' then
    return jsonb_build_object('side', 'user',
      'threads', (select coalesce(jsonb_agg(_desk_json(t, 'user') order by (t.status = 'open') desc, t.last_at desc, t.id desc), '[]'::jsonb)
                    from (select * from desk_threads where user_id = u order by (status = 'open') desc, last_at desc, id desc limit 100) t));
  end if;
  select * into c from companies where cid = _cid_norm(p_cid);
  if not found or not _desk_staff(c.id, u) then raise exception 'この会社の窓口の担当ではありません'; end if;
  return jsonb_build_object('side', 'corp', 'cid', c.cid, 'company', c.name, 'status', c.status, 'desk_on', c.desk_on, 'desk_note', c.desk_note, 'owner', c.owner = u,
    'threads', (select coalesce(jsonb_agg(_desk_json(t, 'corp') order by (t.status = 'open') desc, t.last_at desc, t.id desc), '[]'::jsonb)
                  from (select * from desk_threads where company_id = c.id order by (status = 'open') desc, last_at desc, id desc limit 100) t));
end $$;

-- 会社の窓口で、まだ読んでいない相談の数
create or replace function public._desk_unread(cid_int int) returns int
language sql stable set search_path = public as $$
  select count(*)::int from desk_threads t
   where t.company_id = cid_int and exists (select 1 from desk_msgs m where m.thread_id = t.id and not m.from_corp and m.id > t.corp_seen)
$$;

-- 社長：窓口の受付と案内
create or replace function public.desk_settings(p_cid text, p_on boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if c.status not in ('active', 'suspended') then raise exception 'この会社はいま変えられません'; end if;
  update companies set desk_on = coalesce(p_on, desk_on), desk_note = left(btrim(coalesce(p_note, desk_note)), 300) where id = c.id;
  return my_corps();
end $$;

-- 社長：社員を窓口担当にする・はずす
create or replace function public.corp_member_desk(p_cid text, p_user text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; m uuid;
begin
  c := _my_corp(u, p_cid);
  select id into m from profiles where account_no = btrim(coalesce(p_user, ''));
  if not found or not exists (select 1 from corp_members where company_id = c.id and user_id = m) then raise exception 'その社員はいません'; end if;
  if (select desk from corp_members where company_id = c.id and user_id = m) = coalesce(p_on, false) then return my_corps(); end if;
  update corp_members set desk = coalesce(p_on, false) where company_id = c.id and user_id = m;
  perform _notice_l(m, case when p_on then format('【窓口】「%s」の窓口担当になりました。「仕事 → 勤め先」から相談に返事できます。', c.name)
                            else format('【窓口】「%s」の窓口担当からはずれました。', c.name) end,
                    jsonb_build_object('go', 'mywork'), u);
  return my_corps();
end $$;

-- ---------------------------------------------------------------------
-- 管理：登録した人の一覧（管理者・副管理者）
--   所持金は出さない。メールアドレス・税の滞納・脱税は管理者だけ
-- ---------------------------------------------------------------------

create or replace function public._user_row(p public.profiles, adm boolean) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('uid', p.account_no, 'nickname', p.nickname, 'badge', _badge(p.id),
    'joined', to_char(p.created_at at time zone 'Asia/Tokyo', 'YYYY/MM/DD HH24:MI'),
    'seen', case when p.last_seen_at is null then null else to_char(p.last_seen_at at time zone 'Asia/Tokyo', 'YYYY/MM/DD HH24:MI') end,
    'mail_at', case when p.mail_verified_at is null then null else to_char(p.mail_verified_at at time zone 'Asia/Tokyo', 'YYYY/MM/DD') end,
    'email', case when adm then (select to_jsonb(a)->>'email' from auth.users a where a.id = p.id) end,
    'banned_until', case when p.banned_until > _now() then to_char(p.banned_until at time zone 'Asia/Tokyo', 'YYYY/MM/DD HH24:MI') end,
    'debt', case when adm then _debt(p.id) > 0 end,
    'new', _now() < p.created_at + interval '7 days',
    'corps', (select count(*) from companies c where c.owner = p.id and c.status in ('pending', 'active', 'suspended')),
    'guest', (select to_char(_guest_until(g.id) at time zone 'Asia/Tokyo', 'YYYY/MM/DD HH24:MI') from guests g where g.id = p.id))
$$;

create or replace function public.admin_users(p_q text, p_filter text, p_offset int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); rl text := _role(u); adm boolean := _role(u) = 'admin';
  q text := btrim(coalesce(p_q, '')); f text := coalesce(p_filter, ''); ofs int := greatest(coalesce(p_offset, 0), 0);
  ids uuid[]; n int;
begin
  if rl is distinct from 'admin' then raise exception '登録者の情報は管理者だけが見られます'; end if;
  if f = 'debt' and not adm then raise exception '税の滞納でしぼれるのは管理者だけです'; end if;
  select array_agg(z.id order by z.created_at desc, z.id), count(*) into ids, n from (
    select p.id, p.created_at from profiles p
     where p.ai is null and (q = '' or p.account_no = q or p.nickname ilike '%' || q || '%'
            or (adm and q like '%@%' and exists (select 1 from auth.users a where a.id = p.id and to_jsonb(a)->>'email' ilike '%' || q || '%')))
       and case f when 'new' then p.created_at > _now() - interval '7 days'
                  when 'banned' then coalesce(p.banned_until > _now(), false)
                  when 'debt' then _debt(p.id) > 0
                  when 'staff' then _role(p.id) is not null
                  when 'guest' then exists (select 1 from guests g where g.id = p.id)
                  else true end) z;
  return jsonb_build_object('total', n, 'more', ofs + 50 < n,
    'items', (select coalesce(jsonb_agg(_user_row(p, adm) order by array_position(ids, p.id)), '[]'::jsonb)
                from profiles p where p.id = any(coalesce(ids[ofs + 1 : ofs + 50], '{}'::uuid[]))),
    'all', (select count(*) from profiles where ai is null),
    'today', (select count(*) from profiles where ai is null and created_at >= (date_trunc('day', _now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo')),
    'week', (select count(*) from profiles where ai is null and created_at > _now() - interval '7 days'),
    'active7', (select count(*) from profiles where ai is null and last_seen_at > _now() - interval '7 days'),
    'guests', (select count(*) from guests));
end $$;

create or replace function public.admin_user(p_uid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); rl text := _role(u); adm boolean := _role(u) = 'admin'; p profiles; au jsonb;
begin
  if rl is distinct from 'admin' then raise exception '登録者の情報は管理者だけが見られます'; end if;
  select * into p from profiles where account_no = btrim(coalesce(p_uid, ''));
  if not found then raise exception 'その人は見つかりません'; end if;
  if adm then select to_jsonb(a) into au from auth.users a where a.id = p.id; end if;
  return _user_row(p, adm) || jsonb_build_object(
    'role', _role(p.id),
    'providers', case when adm then coalesce(au->'raw_app_meta_data'->'providers', '[]'::jsonb) end,
    'last_sign_in', case when au->>'last_sign_in_at' is null then null
                         else to_char((au->>'last_sign_in_at')::timestamptz at time zone 'Asia/Tokyo', 'YYYY/MM/DD HH24:MI') end,
    'mail_ok', p.mail_verified_at is not null and p.mail_verified_at >= _now() - interval '183 days',
    'send_ok', _now() >= coalesce(p.ok7_at, p.created_at + interval '7 days'),
    'debt_amount', case when adm then _debt(p.id) end,
    'evasion', case when adm then (select count(*) from tax_returns where user_id = p.id and evasion) end,
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'kind', c.kind, 'status', _cstat(c.status)) order by c.id), '[]'::jsonb)
                    from companies c where c.owner = p.id and c.status <> 'rejected'),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'role', m.role, 'desk', m.desk) order by m.joined_at), '[]'::jsonb)
               from corp_members m join companies c on c.id = m.company_id where m.user_id = p.id),
    'cases_filed', (select count(*) from court_cases where plaintiff = p.id),
    'cases_against', (select count(*) from court_cases where defendant_user = p.id),
    'friends', (select count(*) from friends where status = 'ok' and (from_user = p.id or to_user = p.id)),
    'posts', (select count(*) from posts where user_id = p.id),
    'pubs', (select count(*) from pubs where author = p.id and status <> 'deleted'),
    'desk', (select count(*) from desk_threads where user_id = p.id),
    'last_play', (select to_char(max(created_at) at time zone 'Asia/Tokyo', 'YYYY/MM/DD HH24:MI') from tx_log where user_id = p.id));
end $$;

-- ---------------------------------------------------------------------
-- 上場と株の売買
--   株式会社（国営はのぞく）の社長が上場を申請し、管理者・副管理者が審査する
--   上場した株は、国営の風の芽証券取引所の板で X で売り買いする（指値。値段は1株あたりの X・整数）
--   約定の値段は、先に出ていた注文の値段。自分の注文どうしは合わせない（自分の注文とぶつかる値段は出せない）
--   値幅制限（ストップ高・ストップ安）：1日（日本時間 0:00〜24:00）に動ける値段の幅を、前の日までの最後の値段（基準値段）から
--     東証と同じ表で決める（例：基準値段 100 X 未満は上下 30 X、1,000 X 未満は上下 150 X）
--     ストップ高＝基準値段＋値幅、ストップ安＝基準値段−値幅（1 X より下にはならない）。この幅の外の値段では注文できない
--     前の日までに出ていて幅の外にある注文は、幅のはしの値段で約定する（ストップ高より高い買い注文は、ストップ高の値段で買える）
--     前の日までに取引がない株（はじめて取引がある日）は、値幅制限なし
--   手数料は取引所の手数料（%）を、買う人・売る人の両方から X で（切り捨て）。取引所のお金になる
--   登録から7日たってから。買うのは税金の滞納がないとき。出せる注文は30件まで
--   会社か取引所が休業中は売買停止（取り消しはできる）。上場廃止・廃業・倒産では、注文を取り消して返す
--   上場している会社は、発行株数を変えられない（株主を守るため）
-- ---------------------------------------------------------------------
-- 国営の取引所
create or replace function public._stock_exch() returns companies
language sql stable set search_path = public as $$
  select * from companies where cid = (select value from app_settings where key = 'exchange_cid') and official limit 1
$$;

create index if not exists stock_trades_corp_time_idx on public.stock_trades(company_id, created_at);
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'stock_trades_buyer_fkey' and confdeltype <> 'n') then
    alter table public.stock_trades alter column buyer drop not null, alter column seller drop not null;
    alter table public.stock_trades drop constraint stock_trades_buyer_fkey, drop constraint if exists stock_trades_seller_fkey;
    alter table public.stock_trades add constraint stock_trades_buyer_fkey foreign key (buyer) references public.profiles(id) on delete set null,
                                    add constraint stock_trades_seller_fkey foreign key (seller) references public.profiles(id) on delete set null;
  end if;
end $$;

-- 東証の制限値幅の表（基準値段 → 上下の幅）
create or replace function public._stock_width(b bigint) returns bigint
language sql immutable as $$
  select (case
    when b <      100 then      30 when b <      200 then      50 when b <      500 then      80 when b <      700 then     100
    when b <     1000 then     150 when b <     1500 then     300 when b <     2000 then     400 when b <     3000 then     500
    when b <     5000 then     700 when b <     7000 then    1000 when b <    10000 then    1500 when b <    15000 then    3000
    when b <    20000 then    4000 when b <    30000 then    5000 when b <    50000 then    7000 when b <    70000 then   10000
    when b <   100000 then   15000 when b <   150000 then   30000 when b <   200000 then   40000 when b <   300000 then   50000
    when b <   500000 then   70000 when b <   700000 then  100000 when b <  1000000 then  150000 when b <  1500000 then  300000
    when b <  2000000 then  400000 when b <  3000000 then  500000 when b <  5000000 then  700000 when b <  7000000 then 1000000
    when b < 10000000 then 1500000 when b < 15000000 then 3000000 when b < 20000000 then 4000000 when b < 30000000 then 5000000
    when b < 50000000 then 7000000 else 10000000 end)::bigint
$$;

-- その日（日本時間）の 0:00
create or replace function public._jday_start(d date) returns timestamptz
language sql stable as $$ select d::timestamp at time zone 'Asia/Tokyo' $$;

-- 基準値段：その日より前の、最後の取引の値段（なければ null）
--   いまの上場より前の取引は数えない（上場しなおした日は値幅制限なし）。その日がいまの上場より前なら、前の上場のときの取引で
create or replace function public._stock_base(cid_int int, d date) returns bigint
language sql stable set search_path = public as $$
  select coalesce(
    (select t.price from stock_trades t
      where t.company_id = cid_int and t.created_at < _jday_start(d)
        and t.created_at >= coalesce((select coalesce(c.price_from, c.listed_at) from companies c where c.id = cid_int and coalesce(c.price_from, c.listed_at) < _jday_start(d + 1)), '-infinity'::timestamptz)
      order by t.created_at desc, t.id desc limit 1),
    (select c.ipo_price from companies c where c.id = cid_int and c.listed and coalesce(c.price_from, c.listed_at) < _jday_start(d + 1)))   -- 上場した日（決めなおした日）は公開価格
$$;

-- 実際の値幅：東証の表の何倍か（app_settings の stock_band_x。ないときは4倍）
create or replace function public._stock_width_x(b bigint) returns bigint
language sql stable set search_path = public as $$
  select floor(_stock_width(b) * coalesce((select value::numeric from app_settings where key = 'stock_band_x'), 4))::bigint
$$;

-- その日の値幅：基準値段・ストップ安・ストップ高（基準値段がなければ、どれも null＝値幅制限なし）
create or replace function public._stock_band(cid_int int, d date, out base bigint, out lo bigint, out hi bigint)
language plpgsql stable set search_path = public as $$
begin
  base := _stock_base(cid_int, d);
  if base is not null then lo := greatest(base - _stock_width_x(base), 1); hi := base + _stock_width_x(base); end if;
end $$;

-- 取引の時刻：ロックを取ったあとの実際の時刻（日付の変わり目で、前の日の取引があとから入らないように）。テストの fake_now があればその時刻
create or replace function public._tnow() returns timestamptz
language sql volatile set search_path = public as $$
  select coalesce((select value::timestamptz from app_settings where key = 'fake_now'), clock_timestamp())
$$;

-- 1つの株の、その日のようす（基準値段・値幅・始値・高値・安値・終値・出来高・売買代金・ストップ高／安）
--   stop：終値がストップ高（high）・ストップ安（low）。touched：一時ストップ高・安になった（high / low / both）
create or replace function public._stock_day(cid_int int, d date) returns jsonb
language plpgsql stable set search_path = public as $$
declare bd record; t0 timestamptz := _jday_start(d); t1 timestamptz := _jday_start(d + 1); t record; op bigint; cl bigint; pf timestamptz;
begin
  select * into bd from _stock_band(cid_int, d);
  pf := (select coalesce(price_from, listed_at) from companies where id = cid_int);
  if pf >= t0 and pf < t1 then t0 := pf; end if;          -- その日に上場・決めなおしがあれば、そこから
  select max(price) hp, min(price) lp, coalesce(sum(qty), 0)::bigint vol, coalesce(sum(value), 0)::bigint val, count(*) n into t
    from stock_trades where company_id = cid_int and created_at >= t0 and created_at < t1;
  if t.n > 0 then
    select price into op from stock_trades where company_id = cid_int and created_at >= t0 and created_at < t1 order by created_at, id limit 1;
    select price into cl from stock_trades where company_id = cid_int and created_at >= t0 and created_at < t1 order by created_at desc, id desc limit 1;
  end if;
  return jsonb_build_object('base', bd.base, 'stop_lo', bd.lo, 'stop_hi', bd.hi,
    'open', op, 'high', t.hp, 'low', t.lp, 'close', cl, 'vol', t.vol, 'value', t.val, 'n', t.n,
    'chg', case when cl is not null and bd.base is not null then cl - bd.base end,
    'stop', case when cl is null or bd.base is null then null when cl >= bd.hi then 'high' when cl <= bd.lo and cl < bd.base then 'low' end,
    'touched', case when bd.base is null or t.n = 0 then null
                    when t.hp >= bd.hi and t.lp <= bd.lo and t.lp < bd.base then 'both' when t.hp >= bd.hi then 'high'
                    when t.lp <= bd.lo and t.lp < bd.base then 'low' end);
end $$;

-- 1つの株の相場（だれが売り買いしたかは出さない）
--   きょうのようす（_stock_day）＋板。板は、値幅の外の注文を値幅のはしの値段に入れて見せる（その値段で約定するため）
create or replace function public._stock_market(cid_int int) returns jsonb
language plpgsql stable set search_path = public as $$
declare dy jsonb := _stock_day(cid_int, _kb_jday(_now())); lo bigint := (dy->>'stop_lo')::bigint; hi bigint := (dy->>'stop_hi')::bigint;
begin
  return dy || jsonb_build_object(
    'last', _stock_last(cid_int),
    'bid', (select case when count(*) > 0 then least(max(price), hi) end from stock_orders where company_id = cid_int and side = 'buy' and status = 'open'),
    'ask', (select case when count(*) > 0 then greatest(min(price), lo) end from stock_orders where company_id = cid_int and side = 'sell' and status = 'open'),
    'bids', (select coalesce(jsonb_agg(jsonb_build_object('price', p, 'qty', q) order by p desc), '[]'::jsonb) from (
              select least(price, hi) p, sum(remain) q from stock_orders where company_id = cid_int and side = 'buy' and status = 'open' group by 1 order by 1 desc limit 8) z),
    'asks', (select coalesce(jsonb_agg(jsonb_build_object('price', p, 'qty', q) order by p), '[]'::jsonb) from (
              select greatest(price, lo) p, sum(remain) q from stock_orders where company_id = cid_int and side = 'sell' and status = 'open' group by 1 order by 1 limit 8) z),
    'trades', (select coalesce(jsonb_agg(jsonb_build_object('price', price, 'qty', qty, 'ts', _kb_ms(created_at)) order by id desc), '[]'::jsonb) from (
              select * from stock_trades where company_id = cid_int
                 and created_at >= coalesce((select coalesce(price_from, listed_at) from companies where id = cid_int), '-infinity'::timestamptz) order by id desc limit 20) z),
    'chart', (select coalesce(jsonb_agg(jsonb_build_object('price', price, 'ts', _kb_ms(created_at)) order by id), '[]'::jsonb) from (
              select * from stock_trades where company_id = cid_int
                 and created_at >= coalesce((select coalesce(price_from, listed_at) from companies where id = cid_int), '-infinity'::timestamptz) order by id desc limit 100) z),
    'shares', (select shares from companies where id = cid_int));
end $$;

-- 株価のグラフ（p_span：recent＝最近100回の取引／1d・1w・1m＝その期間／all＝はじめての取引から全部）
--   期間のものは、時間で120本までに区切って、終値・高値・安値・出来高にまとめる
create or replace function public.stock_chart(p_cid text, p_span text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c companies; t1 timestamptz := _now(); t0 timestamptz; bk double precision; pts jsonb;
begin
  perform _me_g();
  select * into c from companies where cid = _cid_norm(p_cid);
  if not found then raise exception '会社が見つかりません'; end if;
  if coalesce(p_span, '') not in ('recent', '1d', '1w', '1m', 'all') then raise exception '期間が正しくありません'; end if;
  if p_span = 'recent' then
    return jsonb_build_object('span', p_span, 'points',
      (select coalesce(jsonb_agg(jsonb_build_object('ts', _kb_ms(z.created_at), 'price', z.price, 'hi', z.price, 'lo', z.price, 'vol', z.qty) order by z.id), '[]'::jsonb)
         from (select * from stock_trades where company_id = c.id and created_at >= coalesce(c.price_from, c.listed_at, '-infinity'::timestamptz)
               order by id desc limit 100) z));
  end if;
  t0 := case p_span when '1d' then t1 - interval '1 day' when '1w' then t1 - interval '7 days' when '1m' then t1 - interval '30 days'
                    else (select min(created_at) from stock_trades where company_id = c.id) end;
  if t0 is null then return jsonb_build_object('span', p_span, 'points', '[]'::jsonb); end if;
  bk := greatest(60, extract(epoch from (t1 - t0)) / 120);          -- 1本の長さ（秒）
  select coalesce(jsonb_agg(jsonb_build_object('ts', _kb_ms(z.last_at), 'price', z.cl, 'hi', z.hi, 'lo', z.lo, 'vol', z.vol) order by z.b), '[]'::jsonb) into pts
    from (select floor(extract(epoch from (created_at - t0)) / bk)::int b, (array_agg(price order by id desc))[1] cl,
                 max(price) hi, min(price) lo, sum(qty) vol, max(created_at) last_at
            from stock_trades where company_id = c.id and created_at >= t0 and created_at <= t1 group by 1) z;
  return jsonb_build_object('span', p_span, 'from_ms', _kb_ms(t0), 'to_ms', _kb_ms(t1), 'bucket_s', round(bk), 'points', pts,
    'first', (select _dlabel(min(created_at)) from stock_trades where company_id = c.id));
end $$;

-- メインのメニューのウィジェット：新着ニュース（無料の新聞記事の新しい5本）・株価の一覧・会社ごとの株価（1日の動き）
create or replace function public.home_widgets(p_news boolean, p_stocks boolean, p_cids text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return jsonb_build_object(
    'news', case when coalesce(p_news, false) then (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'title', z.title, 'paper', z.paper, 'ai', z.ai,
                'at', _dlabel(z.created_at), 'time', to_char(z.created_at at time zone 'Asia/Tokyo', 'HH24:MI')) order by z.id desc), '[]'::jsonb)
              from (select i.id, i.title, p.title paper, c.ai, i.created_at
                      from pub_items i join pubs p on p.id = i.pub_id join companies c on c.id = p.company_id
                     where i.free and p.kind = 'paper' and p.status = 'active' and c.status in ('active', 'suspended')
                     order by i.id desc limit 5) z) end,
    'stocks', case when coalesce(p_stocks, false) then _stock_list() end,
    'cos', (select coalesce(jsonb_agg(_stock_day(c.id, _kb_jday(_now())) || jsonb_build_object('cid', c.cid, 'name', c.name, 'ai', c.ai, 'status', c.status,
                'last', _stock_last(c.id),
                'spark', (select coalesce(jsonb_agg(z.p order by z.b), '[]'::jsonb)
                            from (select floor(extract(epoch from (t.created_at - (_now() - interval '1 day'))) / 1800)::int b,
                                         (array_agg(t.price order by t.id desc))[1] p
                                    from stock_trades t where t.company_id = c.id and t.created_at > _now() - interval '1 day' group by 1) z))
              order by array_position(p_cids, c.cid)), '[]'::jsonb)
            from companies c where c.cid = any(coalesce(p_cids, '{}'::text[])) and c.listed and c.status in ('active', 'suspended')));
end $$;

-- 上場している株の一覧（相場・取引所に出す）
create or replace function public._stock_list() returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(j order by (j->>'value')::bigint desc, j->>'name'), '[]'::jsonb) from (
    select _stock_day(c.id, _kb_jday(_now())) || jsonb_build_object('cid', c.cid, 'name', c.name, 'status', c.status, 'shares', c.shares,
             'listed_at', _dlabel(c.listed_at), 'last', l.p, 'cap', l.p * c.shares, 'ai', c.ai, 'parent', (select jsonb_build_object('cid', z.cid, 'name', z.name, 'pct', z.pct) from _corp_parent(c.id) z)) j
      from companies c
      cross join lateral (select _stock_last(c.id) p) l
     where c.listed and c.status in ('active', 'suspended') offset 0) z
$$;

create or replace function public.stock_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare ex companies := _stock_exch();
begin
  perform _me_g();
  return jsonb_build_object('stocks', _stock_list(), 'exch', case when ex.id is null then null
           else jsonb_build_object('cid', ex.cid, 'name', ex.name, 'open', ex.status = 'active', 'fee_pct', ex.fx_fee) end);
end $$;

-- 1つの株の画面（相場＋自分の持ち株・注文）
create or replace function public.stock_state(p_cid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); c companies; ex companies := _stock_exch(); me profiles;
begin
  select * into c from companies where cid = _cid_norm(p_cid);
  if not found or c.status not in ('active', 'suspended') or not (c.listed or exists (select 1 from stock_trades where company_id = c.id)) then
    raise exception 'その会社は上場していません';
  end if;
  select * into me from profiles where id = u;
  return jsonb_build_object('cid', c.cid, 'name', c.name, 'ai', c.ai, 'status', c.status, 'parent', (select jsonb_build_object('cid', z.cid, 'name', z.name, 'pct', z.pct) from _corp_parent(c.id) z), 'listed', c.listed, 'listed_at', _dlabel(c.listed_at), 'ipo_price', c.ipo_price,
    'market', _stock_market(c.id),
    'exch', case when ex.id is null then null else jsonb_build_object('cid', ex.cid, 'name', ex.name, 'open', ex.status = 'active', 'fee_pct', ex.fx_fee) end,
    'can_trade', c.listed and c.status = 'active' and ex.id is not null and ex.status = 'active',
    'shares_mine', coalesce((select shares from corp_holders where company_id = c.id and user_id = u), 0),
    'on_sale', (select coalesce(sum(remain), 0) from stock_orders where company_id = c.id and user_id = u and side = 'sell' and status = 'open'),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'side', side, 'price', price, 'qty', qty, 'remain', remain,
                 'status', status, 'at', _dlabel(created_at), 'time', to_char(created_at at time zone 'Asia/Tokyo', 'HH24:MI'))
                 order by (status = 'open') desc, id desc), '[]'::jsonb)
               from (select * from stock_orders where company_id = c.id and user_id = u order by (status = 'open') desc, id desc limit 30) z),
    'ok_from', case when _now() < coalesce(me.ok7_at, me.created_at + interval '7 days') then _dlabel(coalesce(me.ok7_at, me.created_at + interval '7 days')) end,
    'debt', _debt(u) > 0,
    'balance', _bal(u));
end $$;

-- 注文を1つ取り消して、預けたものを返す（中で使う）
create or replace function public._stock_cancel_order(oid bigint) returns void
language plpgsql set search_path = public as $$
declare o stock_orders;
begin
  select * into o from stock_orders where id = oid and status = 'open' for update;
  if not found then return; end if;
  update stock_orders set status = 'canceled', locked = 0 where id = o.id;
  if o.side = 'buy' then update profiles set balance = balance + o.locked where id = o.user_id;
  else perform _add_shares(o.company_id, o.user_id, o.remain); end if;
end $$;

-- 株の注文を出して、合う注文とすぐ約定する（中で使う。画面からの注文もAIの注文もこれを通る）。注文の id を返す
--   買い：X を手数料こみで預ける／売り：株を預ける。ioc なら、すぐ合わなかった残りは取り消して返す
--   呼ぶ前に、会社の行（for key share）と、この株の順番待ちのロック（pg_advisory_xact_lock(7400, 会社)）を取っておくこと
--   ぶつかりそうな相手の行は、自分とあわせて id の順にロックする（ほかの注文とのデッドロックを防ぐ）
create or replace function public._stock_exec(u uuid, cid_int int, p_side text, p_price bigint, p_qty bigint, ioc boolean) returns bigint
language plpgsql set search_path = public as $$
declare c companies; ex companies := _stock_exch(); o stock_orders; m stock_orders; bo stock_orders; so stock_orders;
  q bigint; v bigint; fb bigint; fs bigint; lockamt bigint; have bigint; fee_tot bigint := 0; bd record; tp bigint; ts timestamptz := _tnow();
  who uuid[];
begin
  select * into c from companies where id = cid_int;
  select * into bd from _stock_band(c.id, _kb_jday(ts));            -- きょうの値幅（基準値段がなければ値幅制限なし）
  if bd.base is not null and (p_price < bd.lo or p_price > bd.hi) then
    raise exception 'きょうの値幅は % 〜 % X です（基準値段 % X。ストップ安〜ストップ高）。この間の値段で注文してください', _fmt(bd.lo), _fmt(bd.hi), _fmt(bd.base);
  end if;
  -- ぶつかりそうな相手（値段の良い順・先に出た順に、数量が足りるまで）と自分の行を、id の順にロック
  if p_side = 'buy' then
    select array_agg(distinct z.user_id) into who from (
      select user_id, sum(remain) over (order by price, id) - remain as before from stock_orders
       where company_id = c.id and side = 'sell' and status = 'open' and price <= p_price and user_id <> u) z where z.before < p_qty;
  else
    select array_agg(distinct z.user_id) into who from (
      select user_id, sum(remain) over (order by price desc, id) - remain as before from stock_orders
       where company_id = c.id and side = 'buy' and status = 'open' and price >= p_price and user_id <> u) z where z.before < p_qty;
  end if;
  perform 1 from profiles where id = any(coalesce(who, '{}'::uuid[]) || u) order by id for update;
  if p_side = 'buy' then
    if exists (select 1 from stock_orders where company_id = c.id and user_id = u and side = 'sell' and status = 'open' and price <= p_price) then
      raise exception '自分の売り注文と同じか高い値段の買い注文は出せません（先に売り注文を取り消してください）';
    end if;
    lockamt := p_price * p_qty + ceil(p_price * p_qty * ex.fx_fee / 100)::bigint;
    update profiles set balance = balance - lockamt where id = u and balance >= lockamt;
    if not found then raise exception 'AiliNaX が足りません（手数料をふくめて % X 必要です）', _fmt(lockamt); end if;
  else
    if exists (select 1 from stock_orders where company_id = c.id and user_id = u and side = 'buy' and status = 'open' and price >= p_price) then
      raise exception '自分の買い注文と同じか安い値段の売り注文は出せません（先に買い注文を取り消してください）';
    end if;
    select shares into have from corp_holders where company_id = c.id and user_id = u for update;
    if coalesce(have, 0) < p_qty then raise exception '売れるのは持っている %株までです（売り注文中の株はのぞく）', coalesce(have, 0); end if;
    update corp_holders set shares = shares - p_qty where company_id = c.id and user_id = u;
    delete from corp_holders where company_id = c.id and user_id = u and shares <= 0;
    lockamt := 0;
  end if;
  insert into stock_orders(company_id, exch_id, user_id, side, price, qty, remain, locked, fee_pct, created_at)
  values (c.id, ex.id, u, p_side, p_price, p_qty, p_qty, lockamt, ex.fx_fee, ts) returning * into o;
  -- 反対側の注文と合わせる（値段の良い順・先に出た順）
  loop
    exit when o.remain = 0;
    if o.side = 'buy' then
      select * into m from stock_orders where company_id = c.id and side = 'sell' and status = 'open' and price <= o.price and user_id <> u
       order by price, id limit 1 for update;
    else
      select * into m from stock_orders where company_id = c.id and side = 'buy' and status = 'open' and price >= o.price and user_id <> u
       order by price desc, id limit 1 for update;
    end if;
    exit when not found;
    q := least(o.remain, m.remain);
    if o.side = 'buy' then bo := o; so := m; else bo := m; so := o; end if;
    tp := m.price;                                      -- 値段は先に出ていた注文（m）の値段
    if bd.base is not null then tp := least(greatest(tp, bd.lo), bd.hi); end if;   -- 値幅の外に残っていた注文は、値幅のはしの値段
    v := q * tp;
    fb := floor(v * bo.fee_pct / 100); fs := floor(v * so.fee_pct / 100);
    if v + fb > bo.locked then raise exception '預かりが足りません（内部エラー）'; end if;
    update stock_orders set remain = remain - q, locked = locked - (v + fb), status = case when remain - q = 0 then 'done' else status end
     where id = bo.id returning * into bo;
    update stock_orders set remain = remain - q, status = case when remain - q = 0 then 'done' else status end
     where id = so.id returning * into so;
    perform _add_shares(c.id, bo.user_id, q);           -- 買った人に株
    perform _give(so.user_id, v - fs);                  -- 売った人に X（手数料を引く）
    insert into stock_trades(company_id, exch_id, buy_order, sell_order, buyer, seller, price, qty, value, fee_buy, fee_sell, created_at)
    values (c.id, ex.id, bo.id, so.id, bo.user_id, so.user_id, tp, q, v, fb, fs, ts);
    perform _log(bo.user_id, 'share_buy', v + fb, 0, jsonb_build_object('company', c.name, 'shares', q, 'price', tp, 'fee', fb, 'exchange', true));
    perform _log(so.user_id, 'share_sell', 0, v - fs, jsonb_build_object('company', c.name, 'shares', q, 'price', tp, 'fee', fs, 'exchange', true));
    fee_tot := fee_tot + fb + fs;
    if bo.remain = 0 and bo.locked > 0 then             -- 買い終わったら、あまった預かりを返す
      update profiles set balance = balance + bo.locked where id = bo.user_id;
      update stock_orders set locked = 0 where id = bo.id returning * into bo;
    end if;
    if m.id = bo.id and bo.status = 'done' then
      perform _notice_l(bo.user_id, format('【株】「%s」の買い注文 #%s（%s株・1株 %s X）が全部約定しました。', c.name, bo.id, _fmt(bo.qty), _fmt(bo.price)),
                        jsonb_build_object('go', 'stock', 'cid', c.cid), null);
    elsif m.id = so.id and so.status = 'done' then
      perform _notice_l(so.user_id, format('【株】「%s」の売り注文 #%s（%s株・1株 %s X）が全部約定しました。', c.name, so.id, _fmt(so.qty), _fmt(so.price)),
                        jsonb_build_object('go', 'stock', 'cid', c.cid), null);
    end if;
    if o.side = 'buy' then o := bo; else o := so; end if;
  end loop;
  if ioc and o.remain > 0 then perform _stock_cancel_order(o.id); end if;   -- すぐ合わなかった残りは取り消す
  if fee_tot > 0 then perform _corp_move(ex.id, fee_tot, 'stock_fee', format('株の売買の手数料 %s X（%s）', _fmt(fee_tot), c.name)); end if;
  return o.id;
end $$;

-- 株の注文（画面から）
create or replace function public.stock_order(p_cid text, p_side text, p_price bigint, p_qty bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; ex companies; me profiles;
begin
  if p_side not in ('buy', 'sell') then raise exception '買いか売りをえらんでください'; end if;
  if p_price is null or p_price < 1 or p_price > 1000000000 then raise exception '値段は1株あたり1〜10億 X にしてください'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 1000000000 then raise exception '数量は1〜10億株にしてください'; end if;
  -- 会社の行を先にロック（上場廃止・廃業の最中なら、終わるのを待ってから最新の状態で判断する）
  select * into c from companies where cid = _cid_norm(p_cid) for key share;
  if not found or not c.listed or c.status not in ('active', 'suspended') then raise exception 'その会社は上場していません'; end if;
  if c.status <> 'active' then raise exception '「%」はいま休業中なので、売買は止まっています（取り消しはできます）', c.name; end if;
  ex := _stock_exch();
  if ex.id is null or ex.status <> 'active' then raise exception '取引所がいま開いていないので、注文できません'; end if;
  perform pg_advisory_xact_lock(7400, c.id);            -- 同じ株の注文は1つずつ
  perform pg_advisory_xact_lock(7401, hashtext(u::text));   -- 同じ人の注文も1つずつ（注文30件までを守る）
  select * into me from profiles where id = u;
  if _now() < coalesce(me.ok7_at, me.created_at + interval '7 days') then raise exception '登録から7日たつまで、株の売り買いはできません（%から）', _dlabel(coalesce(me.ok7_at, me.created_at + interval '7 days')); end if;
  if (select count(*) from stock_orders where user_id = u and status = 'open') >= 30 then raise exception '出せる株の注文は30件までです'; end if;
  if p_side = 'buy' and _debt(u) > 0 then raise exception '税金の滞納があるので、株は買えません'; end if;
  perform _stock_exec(u, c.id, p_side, p_price, p_qty, false);
  return stock_state(c.cid);
end $$;

-- 注文を取り消す
create or replace function public.stock_cancel(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); o stock_orders; cid_int int;
begin
  select company_id into cid_int from stock_orders where id = p_id and user_id = u and status = 'open';
  if not found then raise exception '取り消せる注文が見つかりません'; end if;
  perform 1 from companies where id = cid_int for key share;    -- 注文と同じ順番でロック
  perform pg_advisory_xact_lock(7400, cid_int);
  select * into o from stock_orders where id = p_id and user_id = u and status = 'open' for update;
  if not found then raise exception '取り消せる注文が見つかりません'; end if;
  perform _stock_cancel_order(o.id);
  return stock_state((select cid from companies where id = o.company_id));
end $$;

-- 上場をやめる（中で使う）：注文を全部取り消して返し、知らせる
create or replace function public._stock_delist(cid_int int, why text) returns void
language plpgsql set search_path = public as $$
declare c companies; r record;
begin
  select * into c from companies where id = cid_int;
  for r in select * from stock_orders where company_id = cid_int and status = 'open' order by id loop
    perform _stock_cancel_order(r.id);
    perform _notice_l(r.user_id, format('【株】「%s」が上場廃止になったため、%s注文 #%s を取り消して、預けた%sを返しました。%s', c.name,
                      case when r.side = 'buy' then '買い' else '売り' end, r.id, case when r.side = 'buy' then 'お金' else '株' end,
                      coalesce('理由：' || why, '')), jsonb_build_object('go', 'stock', 'cid', c.cid), null);
  end loop;
  update companies set listed = false where id = cid_int;
  update stock_list_apps set status = 'withdrawn', decided_at = _now() where company_id = cid_int and status = 'pending';
end $$;

-- 差し押さえ・没収の前に、AiliNaX を預けている注文（株の買い・通貨の売り）を取り消して残高にもどす
create or replace function public._unlock_orders(u uuid, why text) returns int
language plpgsql set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from stock_orders where user_id = u and side = 'buy' and status = 'open' order by id loop perform _stock_cancel_order(r.id); n := n + 1; end loop;
  for r in select id from fx_orders where user_id = u and side = 'sell' and status = 'open' order by id loop perform _fx_cancel_order(r.id); n := n + 1; end loop;
  if n > 0 then perform _notice(u, format('【%s】AiliNaX を預けていた注文 %s件を取り消して、残高にもどしました。', why, n)); end if;
  return n;
end $$;

-- 社長：上場を申請する・取り下げる
create or replace function public.stock_list_apply(p_cid text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  if c.official then raise exception '国営の会社は上場できません'; end if;
  if c.form <> '株式会社' then raise exception '上場できるのは株式会社だけです'; end if;
  if c.status <> 'active' then raise exception '営業中の会社だけが申請できます'; end if;
  if c.listed then raise exception 'もう上場しています'; end if;
  if exists (select 1 from stock_list_apps where company_id = c.id and status = 'pending') then raise exception 'もう申請しています（審査をお待ちください）'; end if;
  insert into stock_list_apps(company_id, owner, note, created_at) values (c.id, u, left(btrim(coalesce(p_note, '')), 500), _now());
  return my_corps();
end $$;

create or replace function public.stock_list_withdraw(p_cid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies;
begin
  c := _my_corp(u, p_cid);
  update stock_list_apps set status = 'withdrawn', decided_at = _now() where company_id = c.id and status = 'pending';
  if not found then raise exception '審査中の上場申請はありません'; end if;
  return my_corps();
end $$;

-- 管理者・副管理者：上場の審査
drop function if exists public.admin_stock_decide(text, boolean, text);
create or replace function public.admin_stock_decide(p_cid text, p_ok boolean, p_reason text, p_price bigint default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; a stock_list_apps; why text := nullif(left(btrim(coalesce(p_reason, '')), 300), '');
  n5 bigint; ai_n bigint; have bigint; ais uuid[]; k int; each bigint; gv bigint;
begin
  if not _is_staff(u) then raise exception '管理者だけが使えます'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) for update;
  if not found then raise exception '会社が見つかりません'; end if;
  select * into a from stock_list_apps where company_id = c.id and status = 'pending' order by id desc limit 1 for update;
  if not found then raise exception '審査中の上場申請が見つかりません'; end if;
  if c.owner = u and _role(u) <> 'admin' then raise exception '自分の会社の申請は審査できません'; end if;
  if p_ok then
    if c.status <> 'active' or c.form <> '株式会社' or c.official then raise exception 'この会社はいま上場できません（休業中など）'; end if;
    if p_price is null or p_price < 1 or p_price > 1000000000 then raise exception '公開価格（1株の値段）を1〜10億 X で決めてください'; end if;
    -- 社長の持ち株から発行株数の5%を国へ。そのうち半分は、AIトレーダー（神楽坂通商事・AI投資家）に同じ数ずつ配る
    n5 := floor(c.shares * 0.05)::bigint;
    if n5 > 0 then
      select shares into have from corp_holders where company_id = c.id and user_id = c.owner for update;
      if coalesce(have, 0) < n5 then
        raise exception '上場するには、社長が発行株数の5%%（%株）以上を持っている必要があります（いま %株）', _fmt(n5), _fmt(coalesce(have, 0));
      end if;
      update corp_holders set shares = shares - n5 where company_id = c.id and user_id = c.owner;
      delete from corp_holders where company_id = c.id and user_id = c.owner and shares <= 0;
      select array_agg(id order by (ai = 'kagura') desc, ai) into ais from profiles where ai = 'kagura' or ai like 'inv%';
      ai_n := case when ais is null then 0 else n5 / 2 end;
      if ai_n > 0 then
        k := array_length(ais, 1); each := ai_n / k;
        for i in 1..k loop
          gv := each + (case when i = 1 then ai_n % k else 0 end);          -- あまりは神楽坂通商事
          if gv > 0 then perform _add_shares(c.id, ais[i], gv); end if;
        end loop;
      end if;
      gv := n5 - ai_n;
      if gv > 0 then perform _add_shares(c.id, _gov_uid(), gv); end if;
    end if;
    update companies set listed = true, listed_at = _now(), price_from = _now(), ipo_price = p_price where id = c.id;
    update stock_list_apps set status = 'approved', reason = why, decided_by = u, decided_at = _now() where id = a.id;
    perform _notice_l(c.owner, format('【上場】「%s」が風の芽証券取引所に上場しました。公開価格は1株 %s X で、きょうはこの値段を基準に値幅制限（%s〜%s X）がかかります。株は「企業 → 取引所」で売り買いできます。%s%s',
                      c.name, _fmt(p_price), _fmt(greatest(p_price - _stock_width_x(p_price), 1)), _fmt(p_price + _stock_width_x(p_price)),
                      case when coalesce(n5, 0) > 0 then format('上場にあたり、社長の持ち株から発行株数の5%%（%s株）を国に渡しました（そのうち%s株はAIトレーダーへ）。', _fmt(n5), _fmt(ai_n)) else '' end,
                      coalesce('（' || why || '）', '')), jsonb_build_object('go', 'stock', 'cid', c.cid), u);
  else
    update stock_list_apps set status = 'rejected', reason = why, decided_by = u, decided_at = _now() where id = a.id;
    perform _notice_l(c.owner, format('【上場】「%s」の上場申請は見送りになりました。%s', c.name, coalesce('理由：' || why, '')),
                      jsonb_build_object('go', 'corp', 'cid', c.cid), u);
  end if;
  return admin_state();
end $$;

-- 管理者：上場廃止
create or replace function public.admin_stock_delist(p_cid text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; why text := nullif(left(btrim(coalesce(p_reason, '')), 300), '');
begin
  if _role(u) is distinct from 'admin' then raise exception '上場廃止は管理者だけができます'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) for update;
  if not found or not c.listed then raise exception '上場している会社が見つかりません'; end if;
  perform pg_advisory_xact_lock(7400, c.id);
  perform _stock_delist(c.id, why);
  perform _notice_l(c.owner, format('【上場】「%s」は上場廃止になりました。%s', c.name, coalesce('理由：' || why, '')), jsonb_build_object('go', 'corp', 'cid', c.cid), u);
  return admin_state();
end $$;

-- ---------------------------------------------------------------------
-- 情報タブの「今日」：その日（日本時間）の株式市場・新商品・新しい会社・為替・競馬・ニュースなど
--   30日前までさかのぼって見られる。だれが売り買いしたか・所持金は出さない
-- ---------------------------------------------------------------------
alter table public.corp_items alter column created_at set default public._now();
create index if not exists corp_items_time_idx on public.corp_items(created_at);
create index if not exists fx_trades_exch_time_idx on public.fx_trades(exch_id, created_at);
create index if not exists pub_items_time_idx on public.pub_items(created_at);

create or replace function public.info_today(p_day date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); today date := _kb_jday(_now()); d date := coalesce(p_day, _kb_jday(_now()));
  t0 timestamptz; t1 timestamptz; fx companies; ex companies := _stock_exch(); fxj jsonb;
begin
  if d > today or d < today - 30 then raise exception '見られるのは、きょうから30日前までです'; end if;
  t0 := _jday_start(d); t1 := _jday_start(d + 1);
  begin perform _kb_tick(); exception when others then null; end;    -- 競馬の番組・結果を最新に（うまくいかなくても、ほかは出す）
  -- 為替（AiliNaX ⇄ CA。国営の取引所）
  fx := _fx_pick(null);
  if fx.id is not null then
    select jsonb_build_object('cid', fx.cid, 'name', fx.name,
             'base', (select price from fx_trades where exch_id = fx.id and created_at < t0 order by created_at desc, id desc limit 1),
             'open', (select price from fx_trades where exch_id = fx.id and created_at >= t0 and created_at < t1 order by created_at, id limit 1),
             'close', (select price from fx_trades where exch_id = fx.id and created_at >= t0 and created_at < t1 order by created_at desc, id desc limit 1),
             'high', max(price), 'low', min(price), 'vol', coalesce(sum(qty), 0), 'n', count(*))
      into fxj from fx_trades where exch_id = fx.id and created_at >= t0 and created_at < t1;
  end if;
  return jsonb_build_object(
    'day', d, 'today', d = today, 'min_day', today - 30,
    'label', to_char(d::timestamp, 'FMMM"月"FMDD"日"') || '（' || (array['月','火','水','木','金','土','日'])[extract(isodow from d)::int] || '）',
    'at', case when d = today then to_char(_now() at time zone 'Asia/Tokyo', 'HH24:MI') end,
    -- 株式市場：上場しているすべての株の、その日のようす（売買代金の多い順）
    'exch', case when ex.id is null then null else jsonb_build_object('cid', ex.cid, 'name', ex.name, 'open', ex.status = 'active', 'fee_pct', ex.fx_fee) end,
    'stocks', (select coalesce(jsonb_agg(j order by (j->>'value')::bigint desc, j->>'name'), '[]'::jsonb) from (
        select _stock_day(c.id, d) || jsonb_build_object('cid', c.cid, 'name', c.name, 'status', c.status, 'shares', c.shares,
                 'new', c.listed_at >= t0 and c.listed_at < t1, 'listed', c.listed and c.status in ('active', 'suspended'), 'listed_at', _dlabel(c.listed_at), 'ai', c.ai,
                 'last', coalesce((select price from stock_trades t where t.company_id = c.id and t.created_at < t1
                                    and t.created_at >= coalesce(case when coalesce(c.price_from, c.listed_at) < t1 then coalesce(c.price_from, c.listed_at) end, '-infinity'::timestamptz)
                                  order by t.created_at desc, t.id desc limit 1), case when coalesce(c.price_from, c.listed_at) < t1 then c.ipo_price end)) j
          from companies c
         where (c.listed and c.status in ('active', 'suspended') and c.listed_at < t1)
            or exists (select 1 from stock_trades t where t.company_id = c.id and t.created_at >= t0 and t.created_at < t1)
        offset 0) z),
    -- 新商品（その日に出た商品。なければ、その前の7日の新商品）
    'items', (select coalesce(jsonb_agg(z.j order by z.id desc), '[]'::jsonb) from (
                select i.id, jsonb_build_object('id', i.id, 'name', i.name, 'price', i.price, 'description', left(i.description, 100),
                  'cid', c.cid, 'company', c.name, 'official', c.official, 'ai', c.ai, 'time', to_char(i.created_at at time zone 'Asia/Tokyo', 'HH24:MI')) j
                  from corp_items i join companies c on c.id = i.company_id
                 where i.created_at >= t0 and i.created_at < t1 and i.active and c.status = 'active' order by i.id desc limit 30) z),
    'items_recent', (select coalesce(jsonb_agg(z.j order by z.id desc), '[]'::jsonb) from (
                select i.id, jsonb_build_object('id', i.id, 'name', i.name, 'price', i.price, 'description', left(i.description, 100),
                  'cid', c.cid, 'company', c.name, 'official', c.official, 'at', _dlabel(i.created_at)) j
                  from corp_items i join companies c on c.id = i.company_id
                 where i.created_at >= t0 - interval '7 days' and i.created_at < t0 and i.active and c.status = 'active' order by i.id desc limit 6) z),
    -- 新しくできた会社（その日に審査が通った会社）
    'corps', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'kind', c.kind, 'form', c.form, 'official', c.official, 'ai', c.ai,
                 'parent', (select jsonb_build_object('cid', z.cid, 'name', z.name, 'pct', z.pct) from _corp_parent(c.id) z),
                'industries', c.industries, 'description', left(c.description, 100)) order by c.decided_at), '[]'::jsonb)
              from companies c where c.decided_at >= t0 and c.decided_at < t1 and c.status in ('active', 'suspended')),
    'fx', fxj,
    -- 競馬（その日の番組。メインレースと、きょうなら次のレース）
    'keiba', (select jsonb_build_object('n', count(*), 'night', count(*) filter (where r.no between 30 and 43), 'noon', count(*) filter (where r.no between 44 and 59), 'extra', count(*) filter (where r.no >= 60),
                'settled', count(*) filter (where r.settled),
                'first', to_char(min(r.post) at time zone 'Asia/Tokyo', 'HH24:MI'), 'last', to_char(max(r.post) at time zone 'Asia/Tokyo', 'HH24:MI'),
                'main', (select jsonb_build_object('id', m.id, 'name', m.name, 'grade', m.grade, 'venue', v.name, 'rnum', m.rnum,
                           'surface', m.surface, 'dist', m.dist, 'time', to_char(m.post at time zone 'Asia/Tokyo', 'HH24:MI'), 'status', _kb_status(m),
                           'winner', case when m.settled then (select jsonb_build_object('uma', w.uma, 'name', h.name, 'ninki', w.ninki)
                                         from keiba_entries w join keiba_horses h on h.id = w.horse_id where w.race_id = m.id and w.pos = 1) end)
                           from keiba_races m join keiba_venues v on v.id = m.venue where m.day = d and m.no = 29),
                'next', case when d = today then (select jsonb_build_object('name', x.name, 'grade', x.grade, 'venue', v.name, 'rnum', x.rnum,
                           'time', to_char(x.post at time zone 'Asia/Tokyo', 'HH24:MI'))
                           from keiba_races x join keiba_venues v on v.id = x.venue where x.day = d and x.post > _now() order by x.post limit 1) end)
              from keiba_races r where r.day = d),
    -- ニュース（新聞の無料の記事）と、新しく出た新聞・本（記事・章があるもの）
    'news', (select coalesce(jsonb_agg(z.j order by z.id desc), '[]'::jsonb) from (
               select i.id, jsonb_build_object('id', i.id, 'title', i.title, 'pub_id', p.id, 'paper', p.title, 'by', c.name, 'official', c.official, 'ai', c.ai,
                 'time', to_char(i.created_at at time zone 'Asia/Tokyo', 'HH24:MI')) j
                 from pub_items i join pubs p on p.id = i.pub_id join companies c on c.id = p.company_id
                where i.free and i.created_at >= t0 and i.created_at < t1 and p.kind = 'paper' and p.status = 'active' and c.status in ('active', 'suspended')
                order by i.id desc limit 20) z),
    'pubs', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'title', p.title, 'price', p.price, 'period_days', p.period_days,
               'by', coalesce(c.name, pr.nickname), 'by_company', p.company_id is not null, 'official', coalesce(c.official, false),
               'by_badge', case when p.company_id is null then _badge(p.author) end) order by p.id desc), '[]'::jsonb)
             from pubs p left join companies c on c.id = p.company_id left join profiles pr on pr.id = p.author
            where p.status = 'active' and p.created_at >= t0 and p.created_at < t1
              and (p.company_id is null or c.status in ('active', 'suspended'))
              and exists (select 1 from pub_items pi where pi.pub_id = p.id)),
    -- 登録した人の数
    'joined', (select count(*) from profiles where created_at >= t0 and created_at < t1 and ai is null),
    'players', (select count(*) from profiles where created_at < t1 and ai is null));
end $$;

-- =====================================================================
-- AI会社（ルールとさいころで自動で動く会社。画面ではAIのしるしがつく）
--   神楽坂通商事：取引所でひんぱんに売り買いする。上場しているすべての株（自分の株はのぞく）に、買い・売りの注文を出しておく
--     AI会社の株は、値打ちに少しずつ近づく値段で。プレイヤーの会社の株は、最近10回の取引の真ん中の値段で
--     （プレイヤーの会社の株は、この30日に3人以上が売り買いした株だけ。1社あたり3万 X か資産の3%まで）
--   帝都京浜新聞：毎朝「きのうの株式市場」「新しい会社」、7時と18時に「新商品」、ストップ高・安と新規上場の速報、
--     AI会社の決算と出来事を記事にする（無料。ニュースと「今日」に出る。記者の名前つき）
--   AI投資家（さくら・はやて・しずく・こはる）：AI会社の株を、それぞれの考え方（値打ち・勢い・逆張り・気まぐれ）で売り買いする
--   創業家（AI）：2社の株を持つ。上場のときに株を売り出し、神楽坂通商事の株には買い・売りの注文を出しておく
--   2社とも上場（10万株。公開価格：神楽坂通商事 150 X・帝都京浜新聞 100 X）
--   売上は外の客から毎日（世の中のお金が少しふえる）。決算と配当は毎週月曜9時から（先週の利益の4〜5割）
--   元手は国庫から（神楽坂通商事 800万 X、AI投資家 20万 X ずつ）。管理者は止める・動かす・お金を足すができる
--   pg_cron で毎分 _ai_tick() を呼ぶ（1回に1つの仕事だけして、すぐ終わる）
--   AIのアカウントはログインできず、IDもない（送金・請求・フレンドなどの相手にならない）。人の数・税金・通知・記録には入らない
-- =====================================================================
alter table public.treasury add column if not exists ai_out bigint not null default 0;   -- 国庫からAIに出したお金（元手・足した分）
create table if not exists public.ai_corps (
  company_id int primary key references public.companies(id) on delete cascade,
  role       text not null,
  ipo_price  bigint not null,                  -- 公開価格
  rev_base   numeric not null,                 -- 1日の売上の目安（外の客から）
  margin     numeric not null,                 -- 利益率の目安
  trend      numeric not null default 0.0005,  -- 1日あたりの伸び
  per        numeric not null,                 -- 株価の目安（1年の利益の何倍か）
  payout     numeric not null,                 -- 利益のうち配当にまわす割合
  mood       numeric not null default 1,       -- 評判（出来事で上下する。1がふつう）
  ema_profit numeric not null,                 -- 1日の利益の平均（なめらか）
  started    date not null,
  biz_day    date not null,                    -- 売上を計算した最後の日
  week_done  date not null                     -- まだ決算していない週の月曜
);
create table if not exists public.ai_days (      -- 毎日の売上と費用
  company_id int not null references public.companies(id) on delete cascade,
  day        date not null,
  revenue    bigint not null,
  cost       bigint not null,
  primary key (company_id, day)
);
create table if not exists public.ai_news_log (  -- 同じ記事を2回出さないための印
  kind text not null,
  key  text not null,
  at   timestamptz not null default now(),
  primary key (kind, key)
);
alter table public.ai_corps drop constraint if exists ai_corps_role_check;
alter table public.ai_corps add constraint ai_corps_role_check check (role in ('trade', 'news', 'biz'));
alter table public.ai_corps add column if not exists events jsonb;   -- 出来事の見出しと本文（{name} 会社名・{ceo} 社長）。good / bad
alter table public.ai_corps enable row level security;
alter table public.ai_days enable row level security;
alter table public.ai_news_log enable row level security;
revoke all on public.ai_corps, public.ai_days, public.ai_news_log from anon, authenticated;

-- うわさ（国が新聞に出した良い／悪い記事）。期限まで、AIは「記事を出したときの株価×倍率」に向けて売り買いする
create table if not exists public.ai_buzz (
  company_id int primary key references public.companies(id) on delete cascade,
  base       bigint not null,
  factor     numeric not null,
  until      timestamptz not null
);
alter table public.ai_buzz enable row level security;
revoke all on public.ai_buzz from anon, authenticated;

create or replace function public._ai_buzz_target(co int) returns numeric
language sql stable set search_path = public as $$
  select b.base * b.factor from ai_buzz b where b.company_id = co and b.until > _now()
$$;

-- プレイヤーの会社の1株の値打ち（AIの見方）：会社のお金＋この30日の売上×6＋この30日の配当×36 を株数で割る
create or replace function public._ai_fair_p(co int) returns numeric
language sql stable set search_path = public as $$
  select greatest(1, (c.balance
      + coalesce((select sum(l.amount) from corp_ledger l where l.company_id = c.id and l.kind in ('sale', 'pub') and l.created_at > _now() - interval '30 days'), 0) * 6
      + coalesce((select -sum(l.amount) from corp_ledger l where l.company_id = c.id and l.kind = 'dividend' and l.created_at > _now() - interval '30 days'), 0) * 36
    )::numeric / greatest(c.shares, 1))
  from companies c where c.id = co
$$;

-- AIのアカウントの id（決まった値）
create or replace function public._ai_uid(k text) returns uuid
language sql immutable as $$
  select (case k when 'founder' then 'a1000000-0000-4000-8000-000000000001'
                 when 'kagura'  then 'a1000000-0000-4000-8000-000000000002'
                 when 'inv1'    then 'a1000000-0000-4000-8000-000000000011'
                 when 'inv2'    then 'a1000000-0000-4000-8000-000000000012'
                 when 'inv3'    then 'a1000000-0000-4000-8000-000000000013'
                 when 'inv4'    then 'a1000000-0000-4000-8000-000000000014'
                 when 'inv5'    then 'a1000000-0000-4000-8000-000000000015'
                 when 'inv6'    then 'a1000000-0000-4000-8000-000000000016'
                 when 'inv7'    then 'a1000000-0000-4000-8000-000000000017'
                 when 'inv8'    then 'a1000000-0000-4000-8000-000000000018'
                 when 'inv9'    then 'a1000000-0000-4000-8000-000000000019'
                 when 'inv10'   then 'a1000000-0000-4000-8000-00000000001a' end)::uuid
$$;

-- ふつうの乱数（平均0・標準偏差1）
create or replace function public._randn() returns double precision
language sql volatile as $$ select sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) $$;

-- AIの登場人物の名前
create or replace function public._ai_name() returns text
language sql volatile as $$
  select (array['佐藤','鈴木','高橋','田中','伊藤','渡辺','山本','中村','小林','加藤','吉田','山田','佐々木','山口','松本',
                '井上','木村','林','斎藤','清水','山崎','森','池田','橋本','阿部','石川','前田','藤田','小川','岡田'])[1 + floor(random() * 30)::int]
      || ' ' ||
         (array['健一','誠','大輔','翔太','拓也','直樹','浩二','隆','悠斗','蓮','大和','陽向','湊','樹','颯','美咲','陽子','恵','彩','結衣',
                '真由美','智子','涼子','奈々','葵','凛','結菜','陽菜','芽依','紗希','千尋','遥','舞','優花','杏奈','早紀','美穂','恵美','由佳','明日香'])[1 + floor(random() * 40)::int]
$$;

-- AIのアカウントをつくる（ログインはできない。IDなし。メールは届かないアドレス）
create or replace function public._ai_account(p_id uuid, p_nick text, p_role text) returns void
language plpgsql set search_path = public as $$
declare cols text[];
begin
  if not exists (select 1 from auth.users where id = p_id) then
    select array_agg(column_name::text) into cols from information_schema.columns where table_schema = 'auth' and table_name = 'users';
    if 'email' = any(cols) and 'confirmation_token' = any(cols) and 'banned_until' = any(cols) then
      execute 'insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                 confirmation_token, recovery_token, email_change_token_new, email_change, banned_until)
               values ($1, ''00000000-0000-0000-0000-000000000000'', ''authenticated'', ''authenticated'', $2,
                 ''{"provider":"ai","providers":["ai"]}''::jsonb, ''{"ai":true}''::jsonb, now(), now(), '''', '''', '''', '''', ''2999-12-31'')'
        using p_id, 'ai-' || p_role || '@ailinax.invalid';
    else
      execute 'insert into auth.users (id) values ($1)' using p_id;
    end if;
  end if;
  insert into profiles(id, nickname, balance, created_at, ai) values (p_id, p_nick, 0, _now(), p_role)
  on conflict (id) do update set ai = excluded.ai, nickname = excluded.nickname;
end $$;

-- 国庫からAIのアカウントにお金を出す（行のロックは、アカウント → 国庫 の順）
create or replace function public._ai_fund(u uuid, amt bigint) returns void
language plpgsql set search_path = public as $$
begin
  if amt is null or amt < 1 then raise exception '額は1 X以上にしてください'; end if;
  update profiles set balance = balance + amt where id = u and ai is not null;
  if not found then raise exception 'AIのアカウントが見つかりません'; end if;
  update treasury set balance = balance - amt, ai_out = ai_out + amt where id = 1 and balance >= amt;
  if not found then raise exception '国庫のお金が足りません'; end if;
end $$;

-- AIの社員をやとう（同じ会社に同じ名前の人がいないように）
create or replace function public._ai_hire(co int, p_title text, p_role text, p_desk text) returns void
language plpgsql set search_path = public as $$
declare nm text;
begin
  for i in 1..30 loop
    nm := _ai_name();
    exit when not exists (select 1 from ai_staff where company_id = co and name = nm and left_on is null);
  end loop;
  insert into ai_staff(company_id, name, title, role, desk, joined) values (co, nm, p_title, p_role, coalesce(p_desk, ''), _kb_jday(_now()));
end $$;

-- AI会社の社長の名前
create or replace function public._ai_ceo(co int) returns text
language sql stable set search_path = public as $$
  select name from ai_staff where company_id = co and role = 'ceo' and left_on is null order by id limit 1
$$;

-- アカウントの持ち株（売り注文に出している分もふくむ）の値打ち（最後の値段で）
create or replace function public._ai_stock_value(u uuid) returns numeric
language sql stable set search_path = public as $$
  select coalesce(sum(h.n * coalesce(_stock_last(h.company_id), 0)), 0)
    from (select company_id, sum(n) n from (select company_id, shares n from corp_holders where user_id = u
                                            union all select company_id, remain from stock_orders where user_id = u and side = 'sell' and status = 'open') y
           group by company_id) h
$$;

-- AI会社の1株の値打ち（AIの見方）：1年の利益 × PER ÷ 株数 × 評判。神楽坂通商事は運用しているお金と株の半分も足す
create or replace function public._ai_fair(co int) returns numeric
language plpgsql stable set search_path = public as $$
declare a ai_corps; sh bigint; v numeric; k uuid := _ai_uid('kagura');
begin
  select * into a from ai_corps where company_id = co;
  if not found then return null; end if;
  sh := greatest((select shares from companies where id = co), 1);
  v := greatest(a.ema_profit, 0) * 365 * a.per / sh * a.mood;
  if a.role = 'trade' then
    v := v + (coalesce((select balance from profiles where id = k), 0)
              + coalesce((select sum(locked) from stock_orders where user_id = k and side = 'buy' and status = 'open'), 0)
              + _ai_stock_value(k)) * 0.5 / sh;
  end if;
  return greatest(v, 1);
end $$;

-- 帝都京浜新聞に記事をのせる（無料。ニュースに出る）。最後にその部の記者の名前を入れる
create or replace function public._ai_article(p_title text, p_body text, p_desk text) returns bigint
language plpgsql set search_path = public as $$
declare pid bigint; w text; iid bigint;
begin
  select p.id into pid from pubs p join ai_corps a on a.company_id = p.company_id
   where a.role = 'news' and p.kind = 'paper' and p.status = 'active' order by p.id limit 1;
  if pid is null then return null; end if;
  select s.name into w from ai_staff s join ai_corps a on a.company_id = s.company_id
   where a.role = 'news' and s.desk = p_desk and s.left_on is null order by random() limit 1;
  insert into pub_items(pub_id, title, body, free, created_at)
  values (pid, left(p_title, 60), p_body || E'\n\n（帝都京浜新聞 ' || p_desk || coalesce('　' || w, '') || '）', true, _now())
  returning id into iid;
  update pubs set updated_at = _now() where id = pid;
  return iid;
end $$;

-- AI会社の出来事（記事になり、評判が上下する）
create or replace function public._ai_event(co int) returns void
language plpgsql set search_path = public as $$
declare a ai_corps; c companies; good boolean := random() < 0.55; sh numeric := 0.03 + random() * 0.06; i int := 1 + floor(random() * 3)::int;
  ceo text; t text; b text; ek text; ev jsonb;
begin
  select * into a from ai_corps where company_id = co;
  select * into c from companies where id = co;
  ceo := coalesce(_ai_ceo(co), '社長');
  if a.role = 'trade' then
    if good then
      t := (array['大型の注文を受ける', '新しい取引先と提携', '物流を見直して費用をへらす'])[i];
      b := (array[
        format('%sは、大口の取引先から大型の注文を受けたと発表した。来週以降の売上がふえる見込みだ。社長の%s氏は「お客さまの期待にこたえたい」と話した。', c.name, ceo),
        format('%sは、新しい取引先と長く取引を続ける約束をした。あつかう品物がふえ、商売の幅が広がる。', c.name),
        format('%sは、倉庫と配送のしくみを見直し、費用をおさえると発表した。利益がふえると見られている。', c.name)])[i];
    else
      t := (array['取引先の支払いが遅れる', '仕入れの値段が上がる', '天候で輸送が遅れる'])[i];
      b := (array[
        format('%sは、一部の取引先からの支払いが遅れていると発表した。しばらく利益がへる見込みだ。', c.name),
        format('%sが仕入れている品物の値段が上がっている。社長の%s氏は「お客さまへの影響はできるだけおさえる」としている。', c.name, ceo),
        format('天候の影響で輸送が遅れ、%sの一部の取引が来週にずれこむ見込みとなった。', c.name)])[i];
    end if;
  else
    if good then
      t := (array['本紙の読者がふえる', '新しい連載を始める', '広告の申しこみが好調'])[i];
      b := (array[
        format('本紙（%s）の読者がふえている。株式市場の記事がよく読まれているという。社長の%s氏は「読者の声にこたえる紙面をつくる」と話した。', c.name, ceo),
        format('本紙（%s）は、来週から企業の社長にじっくり話を聞く新しい連載を始める。', c.name),
        format('本紙（%s）への広告の申しこみがふえている。売上がふえる見込みだ。', c.name)])[i];
    else
      t := (array['紙の値上がりで費用がふえる', '印刷所の点検で配達が遅れる', 'きのうの記事の誤りをおわび'])[i];
      b := (array[
        format('紙の値段が上がり、本紙（%s）の費用がふえる見込みとなった。', c.name),
        format('印刷所の点検のため、本紙（%s）の一部の配達が遅れる。', c.name),
        format('本紙（%s）は、きのうの記事の一部に誤りがあったとして、おわびを出した。社長の%s氏は「確かめるしくみを強める」と話した。', c.name, ceo)])[i];
    end if;
  end if;
  ek := case when good then 'good' else 'bad' end;               -- 会社ごとの出来事の文があれば、そちらを使う
  if a.events is not null and jsonb_array_length(coalesce(a.events->ek, '[]'::jsonb)) > 0 then
    ev := (a.events->ek)->(floor(random() * jsonb_array_length(a.events->ek))::int);
    t := ev->>0; b := replace(replace(ev->>1, '{name}', c.name), '{ceo}', ceo);
  end if;
  update ai_corps set mood = greatest(0.5, least(2.0, mood * (1 + case when good then sh else -sh end))) where company_id = co;
  perform _ai_article(format('【企業】%s、%s', c.name, t), b, '経済部');
end $$;

-- AI会社の1日の商売（外の客からの売上と、仕入れ・給料などの費用）。ときどき出来事
create or replace function public._ai_business(co int, d date) returns void
language plpgsql set search_path = public as $$
declare a ai_corps; c companies; rev bigint; cst bigint; prof bigint; econ numeric;
begin
  select * into a from ai_corps where company_id = co for update;
  if not found or a.biz_day >= d then return; end if;
  select * into c from companies where id = co;
  econ := 0.05 * sin(2 * pi() * extract(doy from d) / 61.0);       -- 景気の波（2か月くらいで1回）
  rev := greatest(0, round(a.rev_base * power(1 + a.trend, greatest(d - a.started, 0)) * (1 + econ) * (1 + 0.12 * _randn()) * power(a.mood, 0.3)))::bigint;
  cst := greatest(0, round(rev * (1 - a.margin * (1 + 0.5 * _randn()))))::bigint;
  if c.status = 'active' then
    if rev > 0 then perform _corp_move(co, rev, 'ai_sale', format('%s の外の客への売上', _dlabel(d))); end if;
    cst := least(cst, (select balance from companies where id = co));
    if cst > 0 then perform _corp_move(co, -cst, 'ai_cost', format('%s の仕入れ・給料など', _dlabel(d))); end if;
  else
    rev := 0; cst := 0;
  end if;
  insert into ai_days(company_id, day, revenue, cost) values (co, d, rev, cst) on conflict do nothing;
  prof := rev - cst;
  update ai_corps set biz_day = d, ema_profit = ema_profit * 0.85 + prof * 0.15,
         mood = greatest(0.5, least(2.0, 1 + (mood - 1) * 0.95 + 0.01 * _randn()))
   where company_id = co;
  if c.status = 'active' and random() < 0.3 then perform _ai_event(co); end if;
end $$;

-- 1週間の決算と配当（wk：その週の月曜）
create or replace function public._ai_settle_week(co int, wk date) returns void
language plpgsql set search_path = public as $$
declare a ai_corps; c companies; rev bigint; cst bigint; prof bigint; prev bigint; div bigint; paid bigint := 0; n int := 0; h record; amt bigint;
  ceo text; b text;
begin
  select * into a from ai_corps where company_id = co for update;
  if not found or a.week_done > wk then return; end if;
  select * into c from companies where id = co;
  select coalesce(sum(x.revenue), 0), coalesce(sum(x.cost), 0) into rev, cst from ai_days x where x.company_id = co and x.day >= wk and x.day < wk + 7;
  prof := rev - cst;
  select coalesce(sum(x.revenue - x.cost), 0) into prev from ai_days x where x.company_id = co and x.day >= wk - 7 and x.day < wk;
  div := case when prof > 0 and c.status = 'active' then floor(prof * a.payout)::bigint else 0 end;
  div := least(div, (select balance from companies where id = co));
  if div > 0 then
    -- 株主の行を、先に id 順でロック（デッドロックを防ぐ）
    perform 1 from profiles where id in (select user_id from _holdings(co)) order by id for update;
    for h in select * from _holdings(co) loop
      amt := floor(div::numeric * h.shares / greatest(c.shares, 1));
      if amt > 0 then
        perform _give(h.user_id, amt);
        perform _log(h.user_id, 'dividend', 0, amt, jsonb_build_object('company', c.name, 'company_id', c.id));
        perform _notice(h.user_id, format('【配当】「%s」から配当 %s X が入りました。', c.name, _fmt(amt)));
        paid := paid + amt; n := n + 1;
      end if;
    end loop;
    if paid > 0 then perform _corp_move(co, -paid, 'dividend', format('配当（%s人に合計 %s X）', n, _fmt(paid))); end if;
  end if;
  update ai_corps set week_done = wk + 7 where company_id = co;
  ceo := coalesce(_ai_ceo(co), '社長');
  b := format('%s（AI）は、%s〜%sの1週間の決算を発表した。売上は %s X、利益は %s X で、利益は前の週より%s。',
              c.name, _dlabel(_jday_start(wk)), _dlabel(_jday_start(wk + 6)), _fmt(rev), _fmt(prof),
              case when prev = 0 then 'くらべられない（はじめての決算）' when prof >= prev then format('%s%% ふえた', round((prof - prev) * 100.0 / greatest(abs(prev), 1), 1))
                   else format('%s%% へった', round((prev - prof) * 100.0 / greatest(abs(prev), 1), 1)) end);
  if paid > 0 then
    b := b || format('株主に合計 %s X の配当を出した（1株あたり %s X）。', _fmt(paid), to_char(paid::numeric / greatest(c.shares, 1), 'FM999990.000'));
  end if;
  b := b || format('社長の%s氏は「%s」と話した。', ceo,
                   case when prof >= prev then '来週も手をぬかずにがんばる' else '立て直しをいそぐ' end);
  perform _ai_article(format('【決算】%s、先週の利益 %s X', c.name, _fmt(prof)), b, '経済部');
end $$;

-- 朝刊（d：きょう）：きのうの株式市場と、きのうできた会社。古いAIの注文の記録もかたづける
create or replace function public._ai_news_morning(d date) returns void
language plpgsql set search_path = public as $$
declare y date := d - 1; t0 timestamptz := _jday_start(d - 1); t1 timestamptz := _jday_start(d); L jsonb; n int; nt int;
  up int; dn int; fl int; nw int; val bigint; vol bigint; capc numeric; b text; lst text; cm text;
begin
  insert into ai_news_log(kind, key, at) values ('morning', d::text, _now()) on conflict do nothing;
  if not found then return; end if;
  delete from stock_orders where status in ('done', 'canceled') and created_at < _now() - interval '3 days'
     and user_id in (select id from profiles where ai is not null);
  -- きのうの株：上場している株と、きのう取引があった株
  select coalesce(jsonb_agg(j), '[]'::jsonb) into L from (
    select _stock_day(c.id, y) || jsonb_build_object('name', c.name, 'shares', c.shares,
             'last', coalesce((select t.price from stock_trades t where t.company_id = c.id and t.created_at < t1
                                and t.created_at >= coalesce(case when coalesce(c.price_from, c.listed_at) < t1 then coalesce(c.price_from, c.listed_at) end, '-infinity'::timestamptz)
                              order by t.created_at desc, t.id desc limit 1), case when coalesce(c.price_from, c.listed_at) < t1 then c.ipo_price end)) j
      from companies c
     where (c.listed and c.status in ('active', 'suspended') and c.listed_at < t1)
        or exists (select 1 from stock_trades t where t.company_id = c.id and t.created_at >= t0 and t.created_at < t1)
    offset 0) z;
  n := jsonb_array_length(L);
  if n > 0 then
    select count(*) filter (where (x->>'n')::int > 0), count(*) filter (where (x->>'chg')::bigint > 0), count(*) filter (where (x->>'chg')::bigint < 0),
           count(*) filter (where (x->>'chg')::bigint = 0), count(*) filter (where x->>'base' is null and (x->>'n')::int > 0),
           coalesce(sum((x->>'value')::bigint), 0), coalesce(sum((x->>'vol')::bigint), 0),
           case when sum((x->>'base')::numeric * (x->>'shares')::numeric) filter (where x->>'base' is not null and x->>'last' is not null) > 0
                then (sum((x->>'last')::numeric * (x->>'shares')::numeric) filter (where x->>'base' is not null and x->>'last' is not null)
                      / sum((x->>'base')::numeric * (x->>'shares')::numeric) filter (where x->>'base' is not null and x->>'last' is not null) - 1) * 100 end
      into nt, up, dn, fl, nw, val, vol, capc
      from jsonb_array_elements(L) x;
    cm := case when capc is null then '' when capc >= 3 then '相場全体は大きく上げた。' when capc >= 0.5 then '相場全体は上げた。'
               when capc > -0.5 then '相場全体はほぼ横ばいだった。' when capc > -3 then '相場全体は下げた。' else '相場全体は大きく下げた。' end;
    b := format('%sの風の芽証券取引所は、上場%s社のうち%s社が値上がりし、%s社が値下がりした（変わらず%s社%s）。売買代金は合計 %s X、出来高は %s株だった。%s',
                _dlabel(t0), n, up, dn, fl, case when nw > 0 then format('、はじめての取引で前の日とくらべられない%s社', nw) else '' end,
                _fmt(val), _fmt(vol), cm);
    if capc is not null then b := b || format('時価総額の合計は前の日より %s%s%%。', case when capc >= 0 then '+' else '−' end, to_char(abs(capc), 'FM990.00')); end if;
    select string_agg(format('・%s　%s X（+%s）', x->>'name', _fmt((x->>'close')::bigint), _fmt((x->>'chg')::bigint)), E'\n') into lst
      from jsonb_array_elements(L) x where x->>'stop' = 'high';
    if lst is not null then b := b || E'\n\n▼ストップ高\n' || lst; end if;
    select string_agg(format('・%s　%s X（−%s）', x->>'name', _fmt((x->>'close')::bigint), _fmt(-(x->>'chg')::bigint)), E'\n') into lst
      from jsonb_array_elements(L) x where x->>'stop' = 'low';
    if lst is not null then b := b || E'\n\n▼ストップ安\n' || lst; end if;
    select string_agg(format('・%s　%s X（+%s%%）', z.nm, _fmt(z.cl), to_char(z.pc, 'FM990.00')), E'\n' order by z.pc desc) into lst from (
      select x->>'name' nm, (x->>'close')::bigint cl, (x->>'chg')::numeric * 100 / (x->>'base')::numeric pc
        from jsonb_array_elements(L) x where (x->>'chg')::bigint > 0 order by 3 desc limit 3) z;
    if lst is not null then b := b || E'\n\n▼値上がり率の上位\n' || lst; end if;
    select string_agg(format('・%s　%s X（−%s%%）', z.nm, _fmt(z.cl), to_char(-z.pc, 'FM990.00')), E'\n' order by z.pc) into lst from (
      select x->>'name' nm, (x->>'close')::bigint cl, (x->>'chg')::numeric * 100 / (x->>'base')::numeric pc
        from jsonb_array_elements(L) x where (x->>'chg')::bigint < 0 order by 3 limit 3) z;
    if lst is not null then b := b || E'\n\n▼値下がり率の上位\n' || lst; end if;
    select string_agg(format('・%s　%s', x->>'name',
                             case when (x->>'n')::int > 0 then format('終値 %s X%s　出来高 %s株', _fmt((x->>'close')::bigint),
                                    case when x->>'chg' is null then '' else format('（%s%s）', case when (x->>'chg')::bigint >= 0 then '+' else '−' end, _fmt(abs((x->>'chg')::bigint))) end,
                                    _fmt((x->>'vol')::bigint))
                                  else format('取引なし（%s X）', coalesce(_fmt((x->>'last')::bigint), '—')) end), E'\n' order by (x->>'value')::bigint desc, x->>'name') into lst
      from (select x from jsonb_array_elements(L) x order by (x->>'value')::bigint desc limit 20) z(x);
    b := b || E'\n\n▼銘柄ごと（売買代金の多い順）\n' || lst;
    perform _ai_article(format('【市況】%sの株式市場　値上がり%s社・値下がり%s社', _dlabel(t0), up, dn), b, '市場部');
  end if;
  -- きのうできた会社（AI会社はのぞく）
  select count(*), string_agg(format('・%s（%s）', c.name,
           coalesce((select string_agg(ic.name, '・' order by ic.code) from industry_codes ic where ic.code = any(c.industries)), '業種はまだ')), E'\n' order by c.decided_at)
    into n, lst from companies c where c.decided_at >= t0 and c.decided_at < t1 and c.status in ('active', 'suspended') and not c.ai;
  if n > 0 then
    perform _ai_article(format('【企業】新しい会社が%s社できた', n),
      format('%sに、新しい会社が%s社できた。', _dlabel(t0), n) || E'\n\n' || lst || E'\n\n' || '会社のページは、企業タブの「会社検索」から見られる。', '経済部');
  end if;
end $$;

-- 新商品の記事（p_kind：items_am / items_pm）。前の記事のあとに出た商品（売っているもの・営業中の会社）
create or replace function public._ai_news_items(p_kind text, d date) returns void
language plpgsql set search_path = public as $$
declare since timestamptz; n int; m int; b text;
begin
  since := coalesce((select max(at) from ai_news_log where kind in ('items_am', 'items_pm', 'items_start')), _now() - interval '1 day');
  insert into ai_news_log(kind, key, at) values (p_kind, d::text, _now()) on conflict do nothing;
  if not found then return; end if;
  select count(*), count(distinct i.company_id) into n, m from corp_items i join companies c on c.id = i.company_id
   where i.created_at > since and i.created_at <= _now() and i.active and c.status = 'active';
  if n = 0 then return; end if;
  select string_agg(z.t, E'\n\n' order by z.nm) into b from (
    select c.name nm, '▼' || c.name || E'\n' || string_agg(format('・%s　%s X%s', i.name, _fmt(i.price),
             case when i.description <> '' then '　「' || left(regexp_replace(i.description, '\s+', ' ', 'g'), 40) || '」' else '' end), E'\n' order by i.id) t
      from corp_items i join companies c on c.id = i.company_id
     where i.created_at > since and i.created_at <= _now() and i.active and c.status = 'active'
     group by c.id, c.name order by c.name limit 20) z;
  perform _ai_article(format('【新商品】新しい商品が%s点', n),
    format('%sまでに、%s社から新しい商品が%s点出た。', to_char(_now() at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24"時"'), m, n)
    || E'\n\n' || b || E'\n\n' || '商品は、それぞれの会社のページから買える（値段には消費税がふくまれる）。', '生活部');
end $$;

-- 速報：きょうストップ高・安になった株、新しく上場した株（1回に1本）
create or replace function public._ai_news_flash(d date) returns boolean
language plpgsql set search_path = public as $$
declare r record; st text;
begin
  for r in select c.id, c.cid, c.name, x.j from companies c cross join lateral (select _stock_day(c.id, d) j offset 0) x
            where c.listed and c.status = 'active' order by c.id loop
    st := r.j->>'stop';
    if st in ('high', 'low') then
      insert into ai_news_log(kind, key, at) values ('stop_' || st, r.cid || ':' || d, _now()) on conflict do nothing;
      if found then
        perform _ai_article(format('【速報】%sがストップ%s', r.name, case st when 'high' then '高' else '安' end),
          format('%sの株価が、きょうの値幅の%s（ストップ%s）の %s X まで%sた。前の日の終値は %s X だった。',
                 r.name, case st when 'high' then '上限' else '下限' end, case st when 'high' then '高' else '安' end,
                 _fmt((r.j->>'close')::bigint), case st when 'high' then '上がっ' else '下がっ' end, _fmt((r.j->>'base')::bigint)), '市場部');
        return true;
      end if;
    end if;
  end loop;
  for r in select c.id, c.cid, c.name, c.shares, c.industries, c.listed_at from companies c
            where c.listed and c.status = 'active' and c.listed_at >= _jday_start(d) - interval '1 day' order by c.id loop
    insert into ai_news_log(kind, key, at) values ('listing', r.cid || ':' || to_char(r.listed_at, 'YYYYMMDDHH24MISS'), _now()) on conflict do nothing;
    if found then
      perform _ai_article(format('【新規上場】%sが上場', r.name),
        format('%sが、風の芽証券取引所に上場した。発行株数は %s株。', r.name, _fmt(r.shares))
        || coalesce('業種は' || (select string_agg(ic.name, '・' order by ic.code) from industry_codes ic where ic.code = any(r.industries)) || '。', ''), '市場部');
      return true;
    end if;
  end loop;
  return false;
end $$;

-- AI投資家の売り買い（上場しているすべての株）。考え方は4つ（inv1・5・9 値打ち／inv2・6・10 勢い／inv3・7 逆張り／inv4・8 気まぐれ）。すぐ約定しなければ7割は取り消す
--   うわさ（国の記事）があれば、目標の値段をそちらに寄せる。プレイヤーの会社1社に入れるのは、自分の資産の4割まで
create or replace function public._ai_invest(u uuid, st text, co int, ref numeric, fv numeric, lo bigint, hi bigint) returns int
language plpgsql set search_path = public as $$
declare lastp bigint; oldp bigint; ret numeric := 0; tg numeric; sd text; px bigint; q bigint; cash bigint; hold bigint; r record;
  aico boolean := exists (select 1 from ai_corps where company_id = co); bz numeric := _ai_buzz_target(co); onsale bigint; nav numeric;
begin
  for r in select id from stock_orders where user_id = u and company_id = co and status = 'open' and created_at < _tnow() - interval '6 hours' loop
    perform _stock_cancel_order(r.id);
  end loop;
  st := 'inv' || ((substr(st, 4)::int - 1) % 4 + 1);      -- 考え方（4つ）
  lastp := coalesce(_stock_last(co), round(ref)::bigint);
  oldp := (select price from stock_trades where company_id = co
             and created_at >= coalesce((select coalesce(price_from, listed_at) from companies where id = co), '-infinity'::timestamptz) order by id desc offset 20 limit 1);
  if oldp is not null and oldp > 0 then ret := (lastp - oldp)::numeric / oldp; end if;
  tg := case st when 'inv1' then fv
                when 'inv2' then lastp * (1 + 2 * ret)
                when 'inv3' then lastp * (1 - 1.5 * ret)
                else lastp * exp(0.06 * _randn()) end;
  if bz is not null then tg := case st when 'inv1' then bz else (tg + bz) / 2 end; end if;   -- うわさに乗る
  if lastp <= 0 or abs(tg - lastp) / lastp < (case st when 'inv1' then 0.02 else 0.005 end) then return 0; end if;
  sd := case when tg > lastp then 'buy' else 'sell' end;
  cash := (select balance from profiles where id = u);
  hold := coalesce((select shares from corp_holders where company_id = co and user_id = u), 0);
  if sd = 'buy' then
    px := ceil(least(tg, lastp * 1.05));
    if lo is not null then px := least(greatest(px, lo), hi); end if;
    q := floor(cash * (0.01 + random() * 0.04) / greatest(px, 1));
    if not aico then      -- プレイヤーの会社：1社あたり資産の4割まで
      onsale := coalesce((select sum(remain) from stock_orders where user_id = u and company_id = co and side = 'sell' and status = 'open'), 0);
      nav := cash + coalesce((select sum(locked) from stock_orders where user_id = u and side = 'buy' and status = 'open'), 0) + _ai_stock_value(u);
      q := least(q, floor(greatest(nav * 0.40 - (hold + onsale) * lastp, 0) / greatest(px, 1))::bigint);
    end if;
  else
    px := floor(greatest(tg, lastp * 0.95));
    if lo is not null then px := least(greatest(px, lo), hi); end if;
    q := floor(hold * (0.04 + random() * 0.12));
  end if;
  if px < 1 or q < 1 then return 0; end if;
  begin
    perform _stock_exec(u, co, sd, px, q, random() < 0.7);
  exception when others then return 0;
  end;
  return 1;
end $$;

-- 市場：上場している株を1つ（板の注文を出しなおす・AI投資家）
create or replace function public._ai_market(co int) returns text
language plpgsql set search_path = public as $$
declare c companies; ex companies := _stock_exch(); a ai_corps; bd record; ts timestamptz := _tnow(); d date := _kb_jday(_tnow());
  k uuid := _ai_uid('kagura'); mm uuid; lastp bigint; ref numeric; fv numeric; s numeric; bid bigint; ask bigint; qb bigint; qa bigint;
  cash bigint; inv bigint; held bigint; cap numeric; r record; nav numeric; bz numeric;
begin
  select * into c from companies where id = co for key share;
  if not found or not c.listed or c.status <> 'active' or ex.id is null or ex.status <> 'active' then return 'skip'; end if;
  perform pg_advisory_xact_lock(7400, c.id);
  -- この株にかかわるアカウントの行を、先に id 順でロック（デッドロックを防ぐ）
  perform 1 from profiles where id in (select p.id from profiles p where p.ai is not null
                                       union select o.user_id from stock_orders o where o.company_id = c.id and o.status = 'open') order by id for update;
  select * into bd from _stock_band(c.id, d);
  select * into a from ai_corps where company_id = c.id;
  lastp := _stock_last(c.id);
  bz := _ai_buzz_target(c.id);                                   -- 国の記事（うわさ）の目標
  if a.company_id is not null then
    fv := _ai_fair(c.id);
    ref := coalesce(lastp, a.ipo_price)::numeric;
    ref := ref * power(coalesce(bz, fv) / ref, case when bz is null then 0.05 else 0.08 end) * exp(0.015 * _randn());   -- 少しずつ値打ち（うわさ）に近づく
    mm := case when a.role = 'trade' then _ai_uid('founder') else k end;   -- 神楽坂通商事の株は創業家が板に出す
  else
    -- プレイヤーの会社の株：値段は最近10回の取引の真ん中（取引がなければ公開価格）。うわさがあれば、そちらへ
    select percentile_cont(0.5) within group (order by z.price) into ref from (select price from stock_trades where company_id = c.id
             and created_at >= coalesce(c.price_from, c.listed_at, '-infinity'::timestamptz) order by id desc limit 10) z;
    ref := coalesce(ref, c.ipo_price);
    if ref is null then return 'skip ' || c.cid; end if;
    if bz is not null then ref := ref * power(bz / ref, 0.08); end if;
    ref := ref * exp(0.01 * _randn());
    fv := _ai_fair_p(c.id);
    mm := k;
  end if;
  if bd.base is not null then ref := least(greatest(ref, bd.lo), bd.hi); end if;
  -- 板の注文を出しなおす（同じ値段のものは、そのまま）
  s := case when a.company_id is null then 0.025 when a.role = 'trade' then 0.02 else 0.01 end;
  bid := floor(ref * (1 - s)); ask := ceil(ref * (1 + s));
  if ask <= bid then ask := bid + 1; end if;
  if bd.base is not null then
    bid := least(greatest(bid, bd.lo), bd.hi); ask := least(greatest(ask, bd.lo), bd.hi);
    if bid >= ask then if ask < bd.hi then ask := bid + 1; else bid := ask - 1; end if; end if;
    if bid < bd.lo then bid := null; end if;
  end if;
  if bid is not null and bid < 1 then bid := null; end if;
  for r in select id, side, price from stock_orders where company_id = c.id and user_id = mm and status = 'open' loop
    if (r.side = 'buy' and r.price is distinct from bid) or (r.side = 'sell' and r.price is distinct from ask) then perform _stock_cancel_order(r.id); end if;
  end loop;
  cash := (select balance from profiles where id = mm);
  inv := coalesce((select shares from corp_holders where company_id = c.id and user_id = mm), 0);
  held := inv + coalesce((select sum(remain) from stock_orders where company_id = c.id and user_id = mm and side = 'sell' and status = 'open'), 0);
  if a.company_id is not null then
    qb := floor(least(cash * 0.005, 100000) / greatest(bid, 1));
    qa := least(inv, floor(held * 0.05)::bigint, floor(100000 / greatest(ask, 1))::bigint);
  else
    nav := cash + coalesce((select sum(locked) from stock_orders where user_id = mm and side = 'buy' and status = 'open'), 0) + _ai_stock_value(mm);
    cap := nav * 0.30;                         -- プレイヤーの会社1社に入れるのは、資産の3割まで（発行株数の1割まで）
    qb := case when held * ref < cap and held < c.shares * 0.10 then least(floor(least(cap - held * ref, 20000) / greatest(bid, 1)), floor(c.shares * 0.10) - held) else 0 end;
    qa := least(inv, floor(20000 / greatest(ask, 1))::bigint);
  end if;
  -- いま出ている同じ値段の注文が半分以上残っていれば、出しなおさない
  if bid is not null and qb > 0 and not exists (select 1 from stock_orders where company_id = c.id and user_id = mm and side = 'buy' and status = 'open' and price = bid and remain * 2 >= qb) then
    for r in select id from stock_orders where company_id = c.id and user_id = mm and side = 'buy' and status = 'open' loop perform _stock_cancel_order(r.id); end loop;
    begin perform _stock_exec(mm, c.id, 'buy', bid, qb, false); exception when others then null; end;
  end if;
  inv := coalesce((select shares from corp_holders where company_id = c.id and user_id = mm), 0);
  qa := least(qa, inv + coalesce((select sum(remain) from stock_orders where company_id = c.id and user_id = mm and side = 'sell' and status = 'open' and price = ask), 0));
  if ask is not null and qa > 0 and not exists (select 1 from stock_orders where company_id = c.id and user_id = mm and side = 'sell' and status = 'open' and price = ask and remain * 2 >= qa) then
    for r in select id from stock_orders where company_id = c.id and user_id = mm and side = 'sell' and status = 'open' loop perform _stock_cancel_order(r.id); end loop;
    inv := coalesce((select shares from corp_holders where company_id = c.id and user_id = mm), 0);
    begin perform _stock_exec(mm, c.id, 'sell', ask, least(qa, inv), false); exception when others then null; end;
  end if;
  -- AI投資家（すべての株）
  for r in select p.id, p.ai from profiles p where p.ai like 'inv%' order by p.id loop
    if random() < 0.5 then perform _ai_invest(r.id, r.ai, c.id, ref, fv, bd.lo, bd.hi); end if;
  end loop;
  return 'market ' || c.cid;
end $$;

-- 止めたあと：AIの注文を、会社ごとに取り消す（1回に1社）
create or replace function public._ai_market_cancel(co int) returns void
language plpgsql set search_path = public as $$
declare r record;
begin
  perform 1 from companies where id = co for key share;
  perform pg_advisory_xact_lock(7400, co);
  perform 1 from profiles where ai is not null order by id for update;
  for r in select o.id from stock_orders o join profiles p on p.id = o.user_id where o.company_id = co and o.status = 'open' and p.ai is not null loop
    perform _stock_cancel_order(r.id);
  end loop;
end $$;

-- AI投資家の5〜10人目（国庫から20万 X ずつ）。もういる人は作らない。作った人数を返す
create or replace function public._ai_add_investors() returns int
language plpgsql set search_path = public as $$
declare n int := 0; x record;
begin
  for x in select * from (values ('inv5', 'AI投資家 つばさ'), ('inv6', 'AI投資家 みなと'), ('inv7', 'AI投資家 あおい'),
                                 ('inv8', 'AI投資家 ひなた'), ('inv9', 'AI投資家 かえで'), ('inv10', 'AI投資家 れん')) v(k, nm) loop
    if not exists (select 1 from profiles where id = _ai_uid(x.k)) then
      perform _ai_account(_ai_uid(x.k), x.nm, x.k);
      perform _ai_fund(_ai_uid(x.k), 200000);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- はじめの準備（1回だけ）：アカウント・元手・2社（上場）・社員・新聞・売り出し
create or replace function public._ai_setup() returns text
language plpgsql set search_path = public as $$
declare f uuid := _ai_uid('founder'); k uuid := _ai_uid('kagura'); ex companies := _stock_exch(); ck int; ct int; d date := _kb_jday(_now());
  mon date := _kb_jday(_now()) - (extract(isodow from _kb_jday(_now()))::int - 1); x text;
begin
  if exists (select 1 from app_settings where key = 'ai_setup') then return 'already'; end if;
  perform pg_advisory_xact_lock(7501);
  if exists (select 1 from app_settings where key = 'ai_setup') then return 'already'; end if;
  if ex.id is null or ex.status <> 'active' then raise exception '国営の取引所が開いていないので、AI会社を始められません'; end if;
  if exists (select 1 from companies where lower(name) in ('神楽坂通商事', '帝都京浜新聞') and status not in ('rejected', 'closed', 'bankrupt')) then
    raise exception '同じ名前の会社がもうあります';
  end if;
  -- アカウント（ログインできない。IDなし）
  perform _ai_account(f, '創業家', 'founder');
  perform _ai_account(k, '神楽坂通商事', 'kagura');
  perform _ai_account(_ai_uid('inv1'), 'AI投資家 さくら', 'inv1');
  perform _ai_account(_ai_uid('inv2'), 'AI投資家 はやて', 'inv2');
  perform _ai_account(_ai_uid('inv3'), 'AI投資家 しずく', 'inv3');
  perform _ai_account(_ai_uid('inv4'), 'AI投資家 こはる', 'inv4');
  -- 元手（国庫から）：神楽坂通商事 800万 X、AI投資家 20万 X ずつ
  perform _ai_fund(k, 8000000);
  foreach x in array array['inv1', 'inv2', 'inv3', 'inv4'] loop perform _ai_fund(_ai_uid(x), 200000); end loop;
  -- 会社（上場。10万株は創業家が持つ）
  insert into companies(cid, owner, name, kind, form, description, status, balance, created_at, decided_at, industries, desk_on, listed, listed_at, shares, ai)
  values (_new_ccode(), f, '神楽坂通商事', '一般', '株式会社',
          '総合商社（AI）。いろいろな品物を外の客と売り買いするほか、風の芽証券取引所で株をひんぱんに売り買いして、上場しているすべての株に買い・売りの注文を出している。社員はAIの登場人物。',
          'active', 0, _now(), _now(), '{50}', false, true, _now(), 100000, true) returning id into ck;
  update companies set ipo_price = 150 where id = ck;
  insert into companies(cid, owner, name, kind, form, description, status, balance, created_at, decided_at, industries, desk_on, listed, listed_at, shares, ai)
  values (_new_ccode(), f, '帝都京浜新聞', '一般', '株式会社',
          '新聞社（AI）。株式市場・新商品・企業のニュースを毎日記事にしている（無料）。記者はAIの登場人物。',
          'active', 0, _now(), _now(), '{41}', false, true, _now(), 100000, true) returning id into ct;
  update companies set ipo_price = 100 where id = ct;
  insert into corp_holders(company_id, user_id, shares) values (ck, f, 100000), (ct, f, 100000);
  insert into ai_corps(company_id, role, ipo_price, rev_base, margin, per, payout, ema_profit, started, biz_day, week_done)
  values (ck, 'trade', 150, 60000, 0.06, 10, 0.4, 60000 * 0.06, d, d - 1, mon),
         (ct, 'news',  100, 20000, 0.10, 14, 0.5, 20000 * 0.10, d, d - 1, mon);
  -- 社員（AIの登場人物）
  perform _ai_hire(ck, '代表取締役社長', 'ceo', '');
  perform _ai_hire(ck, '専務取締役', 'staff', '');
  perform _ai_hire(ck, '運用本部長', 'trader', '運用本部');
  perform _ai_hire(ck, 'トレーダー', 'trader', '運用本部');
  perform _ai_hire(ck, 'トレーダー', 'trader', '運用本部');
  perform _ai_hire(ck, 'トレーダー', 'trader', '運用本部');
  perform _ai_hire(ck, 'アナリスト', 'analyst', '調査部');
  perform _ai_hire(ck, 'アナリスト', 'analyst', '調査部');
  perform _ai_hire(ck, '課長', 'staff', '経理部');
  perform _ai_hire(ck, '主任', 'staff', '営業部');
  perform _ai_hire(ct, '代表取締役社長', 'ceo', '');
  perform _ai_hire(ct, '編集局長', 'staff', '編集局');
  perform _ai_hire(ct, 'デスク', 'reporter', '市場部');
  perform _ai_hire(ct, '記者', 'reporter', '市場部');
  perform _ai_hire(ct, '記者', 'reporter', '市場部');
  perform _ai_hire(ct, '記者', 'reporter', '経済部');
  perform _ai_hire(ct, '記者', 'reporter', '経済部');
  perform _ai_hire(ct, '記者', 'reporter', '生活部');
  perform _ai_hire(ct, 'カメラマン', 'staff', '写真部');
  -- 新聞（無料）
  insert into pubs(kind, company_id, title, description, price, period_days, status, created_at, updated_at)
  values ('paper', ct, '帝都京浜新聞', '株式市場・新商品・企業のニュースを毎日お届けします（無料）。記事はAIの記者が書いています。', 0, 30, 'active', _now(), _now());
  -- 売り出し（公開価格）：創業家が売りに出し、神楽坂通商事とAI投資家が買う。のこりは板に残る（だれでも買える）
  perform pg_advisory_xact_lock(7400, ck); perform pg_advisory_xact_lock(7400, ct);
  perform _stock_exec(f, ck, 'sell', 150, 6000, false);
  perform _stock_exec(f, ct, 'sell', 100, 8000, false);
  perform _stock_exec(k, ct, 'buy', 100, 5000, false);
  foreach x in array array['inv1', 'inv2', 'inv3', 'inv4'] loop
    perform _stock_exec(_ai_uid(x), ck, 'buy', 150, 200, false);
    perform _stock_exec(_ai_uid(x), ct, 'buy', 100, 200, false);
  end loop;
  -- 記事（創刊・上場）。速報で同じ上場の記事を出さないように印をつける
  insert into ai_news_log(kind, key, at)
  select 'listing', c.cid || ':' || to_char(c.listed_at, 'YYYYMMDDHH24MISS'), _now() from companies c where c.id in (ck, ct) on conflict do nothing;
  insert into ai_news_log(kind, key, at) values ('items_start', d::text, _now() - interval '1 day') on conflict do nothing;
  perform _ai_article('【お知らせ】帝都京浜新聞、きょう創刊',
    format('帝都京浜新聞は、きょう創刊した。毎朝「きのうの株式市場」を、朝7時と夕方6時に「新商品」を、ストップ高・ストップ安や新規上場があれば速報をお届けする。記事はすべて無料で、記者はAIである。社長の%s氏は「風の芽の経済の動きを、毎日わかりやすく伝えたい」と話した。', coalesce(_ai_ceo(ct), '')), '編集局');
  perform _ai_article('【新規上場】神楽坂通商事と帝都京浜新聞が上場',
    format('AIが運営する神楽坂通商事（総合商社）と帝都京浜新聞（新聞社）が、きょう風の芽証券取引所に上場した。公開価格は神楽坂通商事が 150 X、帝都京浜新聞が 100 X。発行株数はどちらも10万株で、創業家（AI）が売り出した。神楽坂通商事は、上場しているすべての株に買い・売りの注文を出し、ひんぱんに売り買いする。'), '市場部');
  perform _ai_add_investors();
  insert into app_settings values ('ai_setup', _now()::text) on conflict (key) do nothing;
  insert into app_settings values ('ai_on', '1') on conflict (key) do update set value = '1';
  return 'ok';
end $$;

-- うまくいかなかった仕事の記録（管理の画面に出る）。その仕事はとばして、次へ進む（同じ失敗で毎分止まらないように）
create or replace function public._ai_err(k text, msg text) returns void
language sql set search_path = public as $$
  insert into app_settings values ('ai_error', to_char(_now() at time zone 'Asia/Tokyo', 'FMMM/FMDD HH24:MI') || ' ' || k || '：' || left(coalesce(msg, ''), 300))
  on conflict (key) do update set value = excluded.value
$$;

-- AIの事業会社をつくって上場する（創業家が全部の株を持ち、公開価格で売り出す。神楽坂通商事とAI投資家が買う）
--   p_staff：[[役職, 役割(ceo/staff…), 部署], …]　p_events：{"good": [[見出し, 本文], …], "bad": […]}
create or replace function public._ai_found(p_name text, p_desc text, p_inds text[], p_ipo bigint, p_shares bigint, p_rev numeric, p_margin numeric,
  p_trend numeric, p_per numeric, p_payout numeric, p_sell bigint, p_kagura bigint, p_staff jsonb, p_events jsonb) returns text
language plpgsql set search_path = public as $$
declare f uuid := _ai_uid('founder'); k uuid := _ai_uid('kagura'); co int; c companies; d date := _kb_jday(_now());
  mon date := _kb_jday(_now()) - (extract(isodow from _kb_jday(_now()))::int - 1); x jsonb; r record;
begin
  if not exists (select 1 from app_settings where key = 'ai_setup') then raise exception 'AI会社がまだ始まっていません'; end if;
  if exists (select 1 from companies where name = p_name and status not in ('rejected', 'closed', 'bankrupt')) then raise exception '同じ名前の会社がもうあります'; end if;
  insert into companies(cid, owner, name, kind, form, description, status, balance, created_at, decided_at, industries, desk_on, listed, listed_at, shares, ai, ipo_price)
  values (_new_ccode(), f, p_name, '一般', '株式会社', p_desc, 'active', 0, _now(), _now(), p_inds, false, true, _now(), p_shares, true, p_ipo)
  returning id into co;
  select * into c from companies where id = co;
  insert into corp_holders(company_id, user_id, shares) values (co, f, p_shares);
  insert into ai_corps(company_id, role, ipo_price, rev_base, margin, trend, per, payout, ema_profit, started, biz_day, week_done, events)
  values (co, 'biz', p_ipo, p_rev, p_margin, p_trend, p_per, p_payout, p_rev * p_margin, d, d - 1, mon, p_events);
  for x in select * from jsonb_array_elements(p_staff) loop perform _ai_hire(co, x->>0, x->>1, x->>2); end loop;
  -- 売り出し（公開価格）
  perform pg_advisory_xact_lock(7400, co);
  perform _stock_exec(f, co, 'sell', p_ipo, p_sell, false);
  begin perform _stock_exec(k, co, 'buy', p_ipo, p_kagura, false); exception when others then null; end;
  for r in select id from profiles where ai like 'inv%' order by id loop
    begin perform _stock_exec(r.id, co, 'buy', p_ipo, greatest(1, least(100, (p_sell - p_kagura) / 20)), false); exception when others then null; end;
  end loop;
  insert into ai_news_log(kind, key, at) values ('listing', c.cid || ':' || to_char(c.listed_at, 'YYYYMMDDHH24MISS'), _now()) on conflict do nothing;
  perform _ai_article(format('【新規上場】AIの新会社「%s」が設立、きょう上場', p_name),
    format('AIが運営する新しい会社「%s」が設立され、きょう風の芽証券取引所に上場した。%s公開価格は %s X、発行株数は %s株で、創業家（AI）が %s株を売り出した。社長の%s氏は「みなさんに愛される会社にしたい」と話した。',
           p_name, coalesce(nullif(p_desc, '') || '。', ''), _fmt(p_ipo), _fmt(p_shares), _fmt(p_sell), coalesce(_ai_ceo(co), '')), '経済部');
  return c.cid;
end $$;

-- 毎分（pg_cron）：1回に1つの仕事だけ
create or replace function public._ai_tick() returns text
language plpgsql set search_path = public as $$
declare d date := _kb_jday(_now()); hh int := extract(hour from _now() at time zone 'Asia/Tokyo')::int;
  mon date := _kb_jday(_now()) - (extract(isodow from _kb_jday(_now()))::int - 1); a ai_corps; nx int; co int; r text;
begin
  if not exists (select 1 from app_settings where key = 'ai_setup') then return 'not set up'; end if;
  if not pg_try_advisory_xact_lock(7500) then return 'busy'; end if;
  insert into app_settings values ('ai_last', _now()::text) on conflict (key) do update set value = excluded.value;
  if coalesce((select value from app_settings where key = 'ai_on'), '0') <> '1' then
    -- 止めたあと：AIの注文を1社ずつ取り消す
    select o.company_id into co from stock_orders o join profiles p on p.id = o.user_id where p.ai is not null and o.status = 'open' order by o.company_id limit 1;
    if co is null then return 'off'; end if;
    perform _ai_market_cancel(co);
    return 'stopping';
  end if;
  -- 1) 毎日の商売（きのうまで。1回に1社1日。7日より前はとばす）
  select a2.* into a from ai_corps a2 join companies c on c.id = a2.company_id
   where a2.biz_day < d - 1 and c.status in ('active', 'suspended') order by a2.biz_day, a2.company_id limit 1;
  if found then
    begin
      perform _ai_business(a.company_id, greatest(a.biz_day + 1, d - 7));
    exception
    when deadlock_detected or serialization_failure or lock_not_available then
      perform _ai_err('商売（次の分にやりなおし）', sqlerrm); return 'retry';
    when others then
      perform _ai_err('商売', sqlerrm);
      update ai_corps set biz_day = greatest(a.biz_day + 1, d - 7) where company_id = a.company_id;
    end;
    return 'business';
  end if;
  -- 2) 決算と配当（終わった週を古い順に。いちばん新しい週は月曜9時から）
  select a2.* into a from ai_corps a2 join companies c on c.id = a2.company_id
   where c.status in ('active', 'suspended') and (a2.week_done + 7 < mon or (a2.week_done + 7 = mon and (d > mon or hh >= 9)))
   order by a2.week_done, a2.company_id limit 1;
  if found then
    begin
      perform _ai_settle_week(a.company_id, a.week_done);
    exception
    when deadlock_detected or serialization_failure or lock_not_available then
      perform _ai_err('決算（次の分にやりなおし）', sqlerrm); return 'retry';
    when others then
      perform _ai_err('決算', sqlerrm);
      update ai_corps set week_done = a.week_done + 7 where company_id = a.company_id;
    end;
    return 'week';
  end if;
  -- 3) 朝刊（7時から）
  if hh >= 7 and not exists (select 1 from ai_news_log where kind = 'morning' and key = d::text) then
    begin
      perform _ai_news_morning(d);
    exception
    when deadlock_detected or serialization_failure or lock_not_available then
      perform _ai_err('朝刊（次の分にやりなおし）', sqlerrm); return 'retry';
    when others then
      perform _ai_err('朝刊', sqlerrm);
      insert into ai_news_log(kind, key, at) values ('morning', d::text, _now()) on conflict do nothing;
    end;
    return 'morning';
  end if;
  -- 4) 新商品（7時と18時）
  if hh >= 7 then
    r := case when not exists (select 1 from ai_news_log where kind = 'items_am' and key = d::text) then 'items_am'
              when hh >= 18 and not exists (select 1 from ai_news_log where kind = 'items_pm' and key = d::text) then 'items_pm' end;
    if r is not null then
      begin
        perform _ai_news_items(r, d);
      exception
      when deadlock_detected or serialization_failure or lock_not_available then
        perform _ai_err('新商品（次の分にやりなおし）', sqlerrm); return 'retry';
      when others then
        perform _ai_err('新商品', sqlerrm);
        insert into ai_news_log(kind, key, at) values (r, d::text, _now()) on conflict do nothing;
      end;
      return 'items';
    end if;
  end if;
  -- 5) 速報（うまくいかなければ、とばして市場へ）
  begin
    if _ai_news_flash(d) then return 'flash'; end if;
  exception when others then
    perform _ai_err('速報', sqlerrm);
  end;
  -- 6) 市場（上場している株を、毎分ぜんぶ回る。多いときは10社ずつ順番に）
  r := '';
  for nx in select z.id from (
      (select c.id from companies c where c.listed and c.status = 'active' and c.id > coalesce((select value::int from app_settings where key = 'ai_next'), 0) order by c.id limit 10)
      union all
      (select c.id from companies c where c.listed and c.status = 'active' order by c.id limit 10)) z limit 10 loop
    exit when r like '%% ' || nx || ' %%' or r like '%% ' || nx;
    insert into app_settings values ('ai_next', nx::text) on conflict (key) do update set value = excluded.value;
    begin
      r := r || ' ' || _ai_market(nx);
    exception
    when deadlock_detected or serialization_failure or lock_not_available then
      perform _ai_err('市場（次の分にやりなおし）', sqlerrm); r := r || ' retry';
    when others then
      perform _ai_err('市場', sqlerrm); r := r || ' error';
    end;
  end loop;
  if r = '' then return 'idle'; end if;
  return 'market' || r;
end $$;

-- 管理：AI会社のようす（お金は管理者だけ）
create or replace function public.admin_ai() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); adm boolean := coalesce(_role(u), '') = 'admin'; t0 timestamptz := _jday_start(_kb_jday(_now()));
begin
  if _role(u) is null then raise exception '管理者だけが使えます'; end if;
  return jsonb_build_object(
    'setup', exists (select 1 from app_settings where key = 'ai_setup'),
    'on', coalesce((select value from app_settings where key = 'ai_on'), '0') = '1',
    'last', (select to_char(value::timestamptz at time zone 'Asia/Tokyo', 'FMMM/FMDD HH24:MI:SS') from app_settings where key = 'ai_last'),
    'cron', exists (select 1 from pg_namespace where nspname = 'cron'),
    'error', (select value from app_settings where key = 'ai_error'),
    'admin', adm,
    'corps', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'role', a.role, 'fair', case when adm then round(_ai_fair(c.id)) end, 'mood', round(a.mood, 3),
                 'price', _stock_last(c.id),
                 'balance', case when adm then c.balance end,
                 'week_rev', case when adm then (select coalesce(sum(revenue), 0) from ai_days where company_id = c.id and day >= _kb_jday(_now()) - 7) end,
                 'week_profit', case when adm then (select coalesce(sum(revenue - cost), 0) from ai_days where company_id = c.id and day >= _kb_jday(_now()) - 7) end,
                 'staff', (select count(*) from ai_staff s where s.company_id = c.id and s.left_on is null)) order by c.id), '[]'::jsonb)
                from ai_corps a join companies c on c.id = a.company_id),
    'accounts', case when adm then (select coalesce(jsonb_agg(jsonb_build_object('role', p.ai, 'nickname', p.nickname, 'cash', p.balance,
                 'locked', (select coalesce(sum(locked), 0) from stock_orders o where o.user_id = p.id and o.status = 'open' and o.side = 'buy'),
                 'stocks', round(_ai_stock_value(p.id)),
                 'orders', (select count(*) from stock_orders o where o.user_id = p.id and o.status = 'open')) order by p.ai), '[]'::jsonb)
                from profiles p where p.ai is not null and p.ai <> 'corp') end,
    'ai_out', case when adm then (select ai_out from treasury where id = 1) end,
    'made', case when adm then (select coalesce(sum(revenue - cost), 0) from ai_days) end,
    'articles_today', (select count(*) from pub_items i join pubs p on p.id = i.pub_id join ai_corps a on a.company_id = p.company_id and a.role = 'news'
                        where i.created_at >= t0),
    'trades_today', (select count(*) from stock_trades t where t.created_at >= t0
                       and exists (select 1 from profiles p where p.ai is not null and (p.id = t.buyer or p.id = t.seller))));
end $$;

-- 管理者：AIを動かす（はじめてなら準備も）・止める（AIの注文は数分で取り消される）
create or replace function public.admin_ai_set(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  if coalesce(_role(u), '') <> 'admin' then raise exception '管理者だけが使えます'; end if;
  if p_on then
    if not exists (select 1 from app_settings where key = 'ai_setup') then perform _ai_setup(); end if;
    insert into app_settings values ('ai_on', '1') on conflict (key) do update set value = '1';
  else
    insert into app_settings values ('ai_on', '0') on conflict (key) do update set value = '0';
  end if;
  return admin_ai();
end $$;

-- 管理者：国庫からAIにお金を足す（神楽坂通商事・AI投資家）
create or replace function public.admin_ai_fund(p_who text, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me();
begin
  if coalesce(_role(u), '') <> 'admin' then raise exception '管理者だけが使えます'; end if;
  if p_who is null or (p_who <> 'kagura' and p_who !~ '^inv([1-9]|10)$') then raise exception 'お金を足せるのは、神楽坂通商事とAI投資家だけです'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000000 then raise exception '額は1〜1億 X にしてください'; end if;
  perform _ai_fund(_ai_uid(p_who), p_amount);
  return admin_ai();
end $$;

-- 毎分 AI を動かす（pg_cron があるとき。なければ何もしない）
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron は使えません（AI会社は止まったまま）';
  end;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-ai', '* * * * *', 'select public._ai_tick()');
    perform cron.schedule('ailinax-cron-clean', '17 4 * * *', $c$delete from cron.job_run_details where end_time < now() - interval '3 days'$c$);
  end if;
end $$;

-- =====================================================================
-- 介入（管理者だけ）：国庫の X と、国が持つ CA で、国が取引所に注文を出す（為替介入・株の買い支え／売り）
--   注文は「国（介入）」のアカウント（AIと同じく、IDなし・ログインできない）から出す。すぐ合う分だけ約定し、残りは取り消す
--   終わったら、国のアカウントの X と CA は国庫へもどす（株は国のアカウントが持ち続け、あとで売れる）
--   記事にするかは、そのつど選ぶ（帝都京浜新聞の速報。額は出さない）。記録は管理者だけが見られる
-- =====================================================================
create table if not exists public.interventions (
  id         bigserial primary key,
  kind       text not null,
  company_id int references public.companies(id) on delete set null,   -- 為替なら取引所、株ならその会社
  side       text not null check (side in ('buy', 'sell')),
  price      numeric(20,4) not null,
  qty        bigint not null,
  filled     bigint not null default 0,      -- 約定した数量（X か 株）
  paid       bigint not null default 0,      -- 払った額（為替の買い：CA／株の買い：X）
  got        bigint not null default 0,      -- 受け取った額（為替の売り：CA／株の売り：X）
  before_p   numeric(20,4),
  after_p    numeric(20,4),
  announced  boolean not null default false,
  by_user    uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.interventions drop constraint if exists interventions_kind_check;
alter table public.interventions add constraint interventions_kind_check check (kind in ('fx', 'stock', 'news', 'reprice', 'split', 'give'));
alter table public.interventions add column if not exists note text;      -- 新聞の記事の見出し
alter table public.interventions enable row level security;
revoke all on public.interventions from anon, authenticated;

-- 国（介入）のアカウント（なければ作る）
create or replace function public._gov_uid() returns uuid
language plpgsql set search_path = public as $$
declare g uuid := 'a1000000-0000-4000-8000-000000000099';
begin
  if not exists (select 1 from profiles where id = g) then perform _ai_account(g, '国（介入）', 'gov'); end if;
  return g;
end $$;

-- 国のアカウントの X と CA を、国庫へもどす
create or replace function public._gov_sweep() returns void
language plpgsql set search_path = public as $$
declare g uuid := _gov_uid(); x bigint; c bigint;
begin
  select balance, ca into x, c from profiles where id = g for update;
  if x > 0 or c > 0 then
    update profiles set balance = 0, ca = 0 where id = g;
    update treasury set balance = balance + x, ca_balance = ca_balance + c where id = 1;
  end if;
end $$;

-- 為替の最後の値段（1 X あたりの CA）
create or replace function public._fx_last(xid int) returns numeric
language sql stable set search_path = public as $$
  select price from fx_trades where exch_id = xid order by id desc limit 1
$$;

-- 管理者：介入の画面（国営の取引所の為替・国の持ち株・記録）
create or replace function public.admin_iv_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); xc companies; g uuid := 'a1000000-0000-4000-8000-000000000099';
begin
  if not _is_admin(u) then raise exception '管理者だけが使えます'; end if;
  select * into xc from companies where cid = (select value from app_settings where key = 'exchange_cid');
  return jsonb_build_object(
    'fx', case when xc.id is null then null else jsonb_build_object('cid', xc.cid, 'name', xc.name, 'open', xc.status = 'active' and 'X/CA' = any(xc.fx_pairs),
            'last', _fx_last(xc.id),
            'bid', (select max(price) from fx_orders where exch_id = xc.id and side = 'buy' and status = 'open'),
            'ask', (select min(price) from fx_orders where exch_id = xc.id and side = 'sell' and status = 'open')) end,
    'x', (select balance from treasury where id = 1), 'ca', (select ca_balance from treasury where id = 1),
    'holds', (select coalesce(jsonb_agg(jsonb_build_object('cid', c.cid, 'name', c.name, 'shares', h.shares,
                'price', _stock_last(c.id)) order by c.name), '[]'::jsonb)
              from corp_holders h join companies c on c.id = h.company_id where h.user_id = g),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'side', i.side, 'name', c.name, 'price', i.price, 'qty', i.qty,
                'filled', i.filled, 'paid', i.paid, 'got', i.got, 'before', i.before_p, 'after', i.after_p, 'announced', i.announced, 'note', i.note,
                'by', p.nickname, 'at', _dlabel(i.created_at), 'time', to_char(i.created_at at time zone 'Asia/Tokyo', 'HH24:MI')) order by i.id desc), '[]'::jsonb)
            from (select * from interventions order by id desc limit 30) i left join companies c on c.id = i.company_id left join profiles p on p.id = i.by_user));
end $$;

-- 管理者：国が帝都京浜新聞に記事を出す（良い／悪いうわさ）。ふつうの記事として出る（国が出したことは出ない）
--   p_power：1 小・2 中・3 大。1日のあいだ、AIは「いまの株価×倍率」に向けて売り買いする（良い 1.1／1.25／1.5 倍、悪い 0.9／0.8／0.65 倍）
--   見出し・本文を空にすると、ひな形から作る
create or replace function public.admin_ai_news(p_cid text, p_good boolean, p_power int, p_title text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; base bigint; f numeric; i int := 1 + floor(random() * 3)::int; t text; b text;
begin
  if not _is_admin(u) then raise exception '管理者だけが使えます'; end if;
  if p_good is null then raise exception '良いか悪いかをえらんでください'; end if;
  if p_power is null or p_power not between 1 and 3 then raise exception '強さは 小・中・大 からえらんでください'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません'; end if;
  if not exists (select 1 from pubs p join ai_corps a on a.company_id = p.company_id where a.role = 'news' and p.kind = 'paper' and p.status = 'active') then
    raise exception '帝都京浜新聞がまだありません（AI会社を始めてください）';
  end if;
  t := nullif(left(btrim(coalesce(p_title, '')), 60), '');
  b := nullif(left(btrim(coalesce(p_body, '')), 2000), '');
  if t is null then
    t := case when p_good then (array[format('【企業】%s、大型の契約を結ぶ見込み', c.name), format('【企業】%sの売れ行きが好調', c.name), format('【市場】%sに大口の投資家が関心', c.name)])[i]
              else (array[format('【企業】%s、売上が伸び悩み', c.name), format('【企業】%s、大口の取引先を失う見込み', c.name), format('【市場】%sの株、大口の投資家が売却を検討か', c.name)])[i] end;
  end if;
  if b is null then
    b := case when p_good then (array[format('関係者によると、%sは近く大きな契約を結ぶ見込みだ。売上が大きくふえるとの見方が出ている。', c.name),
                                        format('%sの商品やサービスの売れ行きが好調だ。市場では、利益がふえるとの見方が広がっている。', c.name),
                                        format('複数の大口の投資家が、%sの株に関心を示しているという。', c.name)])[i]
              else (array[format('%sの売上が伸び悩んでいる。関係者は「立て直しには時間がかかる」と話している。', c.name),
                          format('関係者によると、%sは大口の取引先との取引が終わる見込みだ。売上がへるとの見方が出ている。', c.name),
                          format('大口の投資家が、%sの株の売却を考えているとの話が市場で広がっている。', c.name)])[i] end;
  end if;
  perform _ai_article(t, b, '経済部');
  -- 上場している会社なら、1日のあいだ AI がうわさに乗って売り買いする
  base := _stock_last(c.id);
  f := case when p_good then (array[1.1, 1.25, 1.5])[p_power] else (array[0.9, 0.8, 0.65])[p_power] end;
  if c.listed and base is not null then
    insert into ai_buzz(company_id, base, factor, until) values (c.id, base, f, _now() + interval '1 day')
    on conflict (company_id) do update set base = excluded.base, factor = excluded.factor, until = excluded.until;
  end if;
  insert into interventions(kind, company_id, side, price, qty, before_p, after_p, announced, by_user, note, created_at)
  values ('news', c.id, case when p_good then 'buy' else 'sell' end, coalesce(base, 0), p_power, base,
          case when c.listed and base is not null then round(base * f) end, true, u, t, _now());
  return admin_iv_state();
end $$;

-- この株の注文を全部取り消して返す（理由を通知。AIには通知しない）
create or replace function public._stock_cancel_all(cid_int int, why text) returns int
language plpgsql set search_path = public as $$
declare r record; n int := 0; c companies;
begin
  select * into c from companies where id = cid_int;
  perform 1 from profiles where id in (select user_id from stock_orders where company_id = cid_int and status = 'open') order by id for update;
  for r in select * from stock_orders where company_id = cid_int and status = 'open' order by id loop
    perform _stock_cancel_order(r.id);
    perform _notice_l(r.user_id, format('【株】「%s」の%sため、%s注文 #%s（%s株・1株 %s X）を取り消し、預けていた%sを返しました。', c.name, why,
                      case r.side when 'buy' then '買い' else '売り' end, r.id, _fmt(r.remain), _fmt(r.price), case r.side when 'buy' then ' X ' else '株' end),
                      jsonb_build_object('go', 'stock', 'cid', c.cid), null);
    n := n + 1;
  end loop;
  return n;
end $$;

-- 株式分割（1株を p_ratio 株に）：社長（AI会社は管理者）ができる。全員の持ち株が p_ratio 倍、値段は 1/p_ratio に
--   出ている注文は取り消して返す。代金つきの譲渡の申し出は株数を p_ratio 倍（代金はそのまま）。これまでの取引の値段・株数も分割にあわせて直す
create or replace function public.stock_split(p_cid text, p_ratio int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; r record; n int; was bigint;
begin
  if p_ratio is null or p_ratio < 2 or p_ratio > 100 then raise exception '分割は1株を2〜100株にできます'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) for update;
  if not found or c.status not in ('active', 'suspended') then raise exception '会社が見つかりません'; end if;
  if not (_is_admin(u) or (c.owner = u and not c.ai)) then raise exception '株式分割は社長だけができます'; end if;
  if c.form <> '株式会社' then raise exception '株式分割は株式会社だけです'; end if;
  if c.shares * p_ratio > 1000000000000 then raise exception '株数が多くなりすぎます'; end if;
  perform pg_advisory_xact_lock(7400, c.id);
  n := _stock_cancel_all(c.id, '株式分割（1株→' || p_ratio || '株）の');
  update companies set shares = shares * p_ratio, ipo_price = case when ipo_price is null then null else greatest(1, round(ipo_price::numeric / p_ratio)) end where id = c.id;
  update ai_corps set ipo_price = greatest(1, round(ipo_price::numeric / p_ratio)) where company_id = c.id;
  update ai_buzz set base = greatest(1, round(base::numeric / p_ratio)) where company_id = c.id;
  update stock_trades set price = greatest(1, round(price::numeric / p_ratio)), qty = qty * p_ratio where company_id = c.id;
  update share_offers set shares = shares * p_ratio where company_id = c.id and status = 'open';
  for r in select h.user_id, h.shares from corp_holders h where h.company_id = c.id order by h.user_id loop
    update corp_holders set shares = shares * p_ratio where company_id = c.id and user_id = r.user_id;
    perform _notice_l(r.user_id, format('【株】「%s」が株式分割をしました（1株→%s株）。あなたの持ち株は %s株 → %s株になりました（株価は 1/%s）。', c.name, p_ratio,
                      _fmt(r.shares), _fmt(r.shares * p_ratio), p_ratio), jsonb_build_object('go', 'corp', 'cid', c.cid), u);
  end loop;
  insert into interventions(kind, company_id, side, price, qty, announced, by_user, note, created_at)
  values ('split', c.id, 'buy', 0, p_ratio, false, u, format('株式分割 1株→%s株（発行 %s株 → %s株）', p_ratio, _fmt(c.shares), _fmt(c.shares * p_ratio)), _now());
  if c.listed then
    perform _ai_article(format('【企業】%s、株式分割（1株→%s株）', c.name, p_ratio),
      format('%sは、1株を%s株に分ける株式分割をした。発行株数は %s株 から %s株 になり、1株の値段は分割の前のおよそ %s分の1 になる。持ち株の価値は変わらない。',
             c.name, p_ratio, _fmt(c.shares), _fmt(c.shares * p_ratio), p_ratio), '市場部');
  end if;
  return my_corps();
end $$;

-- 管理者：株価を決めなおす（いまから、この値段を公開価格・基準値段にする。出ている注文は取り消して返す）
create or replace function public.admin_stock_reprice(p_cid text, p_price bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); c companies; old bigint; r record;
begin
  if not _is_admin(u) then raise exception '株価を決めなおせるのは管理者だけです'; end if;
  if p_price is null or p_price < 1 or p_price > 1000000000 then raise exception '値段は1〜10億 X にしてください'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) for update;
  if not found or not c.listed or c.status not in ('active', 'suspended') then raise exception 'その会社は上場していません'; end if;
  perform pg_advisory_xact_lock(7400, c.id);
  old := _stock_last(c.id);
  perform _stock_cancel_all(c.id, '株価の決めなおしの');
  update companies set ipo_price = p_price, price_from = _tnow() where id = c.id;   -- ロックを取ったあとの時刻（これより前の取引は使わない）
  update ai_corps set ipo_price = p_price where company_id = c.id;
  delete from ai_buzz where company_id = c.id;
  insert into interventions(kind, company_id, side, price, qty, before_p, after_p, announced, by_user, note, created_at)
  values ('reprice', c.id, 'buy', p_price, 0, old, p_price, false, u, format('株価を決めなおし（%s X → %s X）', coalesce(_fmt(old), '—'), _fmt(p_price)), _now());
  for r in select h.user_id from corp_holders h join profiles p on p.id = h.user_id where h.company_id = c.id and p.ai is null loop
    perform _notice_l(r.user_id, format('【株】「%s」の株価を、管理者が %s X に決めなおしました（きょうはこの値段が基準値段）。', c.name, _fmt(p_price)),
                      jsonb_build_object('go', 'stock', 'cid', c.cid), u);
  end loop;
  return admin_state();
end $$;

-- 管理者：国が持っている株を、人に渡す（p_to が空なら自分に）。代金はなし
create or replace function public.admin_gov_share_give(p_cid text, p_to text, p_shares bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g uuid := 'a1000000-0000-4000-8000-000000000099'; c companies; t record; to_u uuid; to_name text; to_id text; have bigint; tc companies;
begin
  if not _is_admin(u) then raise exception '国の株を渡せるのは管理者だけです'; end if;
  if p_shares is null or p_shares < 1 then raise exception '渡す株数を入れてください'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) for key share;
  if not found then raise exception '会社が見つかりません'; end if;
  if coalesce(btrim(p_to), '') = '' then
    to_u := u;
  else
    select * into t from _find_id(p_to);
    if t.rid is null then   -- 会社：その会社の持ち株に
      to_u := _corp_hold_uid(t.rcomp);
      select * into tc from companies where id = t.rcomp;
    else
      to_u := t.rid;
    end if;
  end if;
  select nickname, account_no into to_name, to_id from profiles where id = to_u;
  if tc.id is not null then to_name := tc.name; to_id := tc.cid; end if;
  perform pg_advisory_xact_lock(7400, c.id);
  select shares into have from corp_holders where company_id = c.id and user_id = g for update;
  if coalesce(have, 0) < p_shares then raise exception '国が持っている「%」の株は %株です', c.name, _fmt(coalesce(have, 0)); end if;
  update corp_holders set shares = shares - p_shares where company_id = c.id and user_id = g;
  delete from corp_holders where company_id = c.id and user_id = g and shares <= 0;
  perform _add_shares(c.id, to_u, p_shares);
  perform _log(to_u, 'gov_share', 0, 0, jsonb_build_object('company', c.name, 'company_id', c.id, 'shares', p_shares));
  if tc.id is not null then
    insert into corp_ledger(company_id, kind, amount, memo, balance_after)
    values (tc.id, 'shares_in', 0, format('「%s」の%s %s を受け取った', c.name, '株', _fmt(p_shares)), tc.balance);
    if tc.owner <> u then
      perform _notice_l(tc.owner, format('【株】国から「%s」の株 %s株を、会社「%s」が受け取りました。「企業 → 持ち株」で見られます。', c.name, _fmt(p_shares), tc.name),
                        jsonb_build_object('go', 'corp', 'cid', c.cid), u);
    end if;
  elsif to_u <> u then
    perform _notice_l(to_u, format('【株】国から「%s」の株 %s株を受け取りました。「企業 → 持ち株」で見られます。', c.name, _fmt(p_shares)),
                      jsonb_build_object('go', 'corp', 'cid', c.cid), u);
  end if;
  insert into interventions(kind, company_id, side, price, qty, by_user, note, created_at)
  values ('give', c.id, 'sell', 0, p_shares, u, format('国の株を %s（ID %s）に %s株', to_name, to_id, _fmt(p_shares)), _now());
  return admin_iv_state();
end $$;

-- 管理者：介入する
--   p_kind：fx（為替。buy＝X を買って CA を払う＝X 高へ／sell＝X を売って CA を受け取る＝X 安へ。値段は 1 X あたりの CA）
--           stock（株。p_cid の株を buy＝買い支え／sell＝国が持っている株を売る。値段は1株の X）
--   p_price までの値段で、すぐ合う分だけ約定（残りは取り消し）。p_announce なら記事にする
create or replace function public.admin_intervene(p_kind text, p_cid text, p_side text, p_price numeric, p_qty bigint, p_announce boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); g uuid; xc companies; c companies; o bigint; fo fx_orders; so stock_orders; bef numeric; aft numeric;
  need bigint; x0 bigint; c0 bigint; x1 bigint; c1 bigint; iv interventions; t text; b text; nm text;
begin
  if not _is_admin(u) then raise exception '介入は管理者だけができます'; end if;
  if p_side not in ('buy', 'sell') then raise exception '買いか売りをえらんでください'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 1000000000 then raise exception '数量は1〜10億にしてください'; end if;
  if p_price is null or p_price <= 0 or p_price > 1000000000 then raise exception '値段を入れてください'; end if;
  g := _gov_uid();
  perform _gov_sweep();
  if p_kind = 'fx' then
    if p_price <> round(p_price, 4) then raise exception '値段は小数第4位までです'; end if;
    select * into xc from companies where cid = (select value from app_settings where key = 'exchange_cid');
    if xc.id is null or xc.status <> 'active' or not ('X/CA' = any(xc.fx_pairs)) then raise exception '国営の取引所がいま開いていません'; end if;
    bef := _fx_last(xc.id);
    -- 国庫から国のアカウントへ（買い：CA／売り：X）
    if p_side = 'buy' then
      need := ceil(p_price * p_qty)::bigint;
      update treasury set ca_balance = ca_balance - need where id = 1 and ca_balance >= need;
      if not found then raise exception '国が持っている CA が足りません（% CA 必要です）', _fmt(need); end if;
      update profiles set ca = ca + need where id = g;
    else
      update treasury set balance = balance - p_qty where id = 1 and balance >= p_qty;
      if not found then raise exception '国庫の X が足りません'; end if;
      update profiles set balance = balance + p_qty where id = g;
    end if;
    select balance, ca into x0, c0 from profiles where id = g;
    o := _fx_exec(g, xc, p_side, p_price, p_qty, true);
    select * into fo from fx_orders where id = o;
    select balance, ca into x1, c1 from profiles where id = g;
    aft := _fx_last(xc.id);
    insert into interventions(kind, company_id, side, price, qty, filled, paid, got, before_p, after_p, announced, by_user, created_at)
    values ('fx', xc.id, p_side, p_price, p_qty, fo.qty - fo.remain,
            case when p_side = 'buy' then fo.spent else 0 end, case when p_side = 'sell' then greatest(c1 - c0, 0) else 0 end,
            bef, aft, coalesce(p_announce, false), u, _now()) returning * into iv;
    if coalesce(p_announce, false) and iv.filled > 0 then
      t := case when p_side = 'buy' then '【速報】国が為替介入　AiliNaX 買い・CA 売り' else '【速報】国が為替介入　AiliNaX 売り・CA 買い' end;
      b := format('国は、%sで %s の為替介入を行った。%s', xc.name,
                  case when p_side = 'buy' then 'AiliNaX を買い、Cièlani-Alpićsk を売る' else 'AiliNaX を売り、Cièlani-Alpićsk を買う' end,
                  case when bef is not null and aft is not null then format('1 X の値段は、介入の前の %s CA から %s CA になった。', to_char(bef, 'FM999999990.0000'), to_char(aft, 'FM999999990.0000'))
                       when aft is not null then format('介入のあと、1 X は %s CA になった。', to_char(aft, 'FM999999990.0000')) else '' end)
           || '介入の額は明らかにしていない。';
      perform _ai_article(t, b, '経済部');
    end if;
  elsif p_kind = 'stock' then
    if p_price <> round(p_price) then raise exception '株の値段は整数（X）です'; end if;
    select * into c from companies where cid = _cid_norm(p_cid) for key share;
    if not found or not c.listed or c.status <> 'active' then raise exception 'その会社は上場していないか、売買が止まっています'; end if;
    xc := _stock_exch();
    if xc.id is null or xc.status <> 'active' then raise exception '取引所がいま開いていません'; end if;
    perform pg_advisory_xact_lock(7400, c.id);
    bef := _stock_last(c.id);
    if p_side = 'buy' then
      need := p_price::bigint * p_qty + ceil(p_price * p_qty * xc.fx_fee / 100)::bigint;
      update treasury set balance = balance - need where id = 1 and balance >= need;
      if not found then raise exception '国庫の X が足りません（% X 必要です）', _fmt(need); end if;
      update profiles set balance = balance + need where id = g;
    else
      if coalesce((select shares from corp_holders where company_id = c.id and user_id = g), 0) < p_qty then
        raise exception '国が持っている「%」の株は %株です', c.name, coalesce((select shares from corp_holders where company_id = c.id and user_id = g), 0);
      end if;
    end if;
    select balance into x0 from profiles where id = g;
    o := _stock_exec(g, c.id, p_side, p_price::bigint, p_qty, true);
    select * into so from stock_orders where id = o;
    select balance into x1 from profiles where id = g;
    aft := _stock_last(c.id);
    insert into interventions(kind, company_id, side, price, qty, filled, paid, got, before_p, after_p, announced, by_user, created_at)
    values ('stock', c.id, p_side, p_price, p_qty, so.qty - so.remain,
            case when p_side = 'buy' then greatest(x0 - x1, 0) else 0 end, case when p_side = 'sell' then greatest(x1 - x0, 0) else 0 end,
            bef, aft, coalesce(p_announce, false), u, _now()) returning * into iv;
    if coalesce(p_announce, false) and iv.filled > 0 then
      t := case when p_side = 'buy' then format('【速報】国が「%s」の株を買い支え', c.name) else format('【速報】国が「%s」の株を売却', c.name) end;
      b := format('国は、%s の株を%s。株価は、介入の前の %s X から %s X になった。%s', c.name,
                  case when p_side = 'buy' then '市場で買い入れた' else '市場で売った' end, _fmt(bef::bigint), _fmt(aft::bigint),
                  '買い入れ・売却の株数は明らかにしていない。');
      perform _ai_article(t, b, '市場部');
    end if;
  else
    raise exception '為替か株をえらんでください';
  end if;
  perform _gov_sweep();     -- のこった X・CA は国庫へ
  return admin_iv_state() || jsonb_build_object('result', jsonb_build_object('filled', iv.filled, 'paid', iv.paid, 'got', iv.got,
           'before', iv.before_p, 'after', iv.after_p, 'kind', iv.kind, 'side', iv.side));
end $$;


-- =====================================================================
-- ゲスト（メールアドレス＋数字4けたのパスワードで、メールの確認なしで始める）
--   ・はじめるとき：guest_signup（ログインなしで呼べる）でアカウントをつくり、画面がそのメールと数字4けたでログインする
--     作りすぎ防止：同じ回線から1日5人まで・サイト全体で1時間60人まで
--   ・31日で消える。5日間ログインしない（サイトを開かない・遊ばない）と、その前に消える（10分ごとに _guest_purge）
--     消えると、所持金・記録もなくなる（対戦の部屋にいるあいだは、終わるまで待つ）
--   ・本登録：メールのリンクでログインする（＝メールを確認できた）と、所持金・記録のまま、ふつうの登録になる
--     数字4けたのパスワードは使えなくなる（6文字以上のパスワードを決めてもらう）
--   ・ゲストのあいだ：所持金は40,000 Xまで（こえた分は受け取れない）・賭け金は1回100 Xまで・送金は5日間で2,000 Xまで
--     はじめてから7日は送金できない（app_settings の guest_wait7 を 0 にすると、すぐ送れる）・送金は受け取れない
--     税金・給付金の対象外・競馬億万長者や人数・人さがしには出ない
--   ・消えたゲストの所持金と、上限をこえて受け取れなかった分は、運営（ID 76705）へ
-- =====================================================================
-- いまの回線（作りすぎ防止に使う。わからなければ null）
create or replace function public._req_ip() returns text
language plpgsql stable set search_path = public as $$
declare h jsonb;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then return null;
  end;
  if h is null then return null; end if;
  return left(coalesce(nullif(btrim(h->>'cf-connecting-ip'), ''), nullif(btrim(split_part(h->>'x-forwarded-for', ',', 1)), ''),
                       nullif(btrim(h->>'x-real-ip'), '')), 64);
end $$;

-- ゲストの状態（画面用）。ゲストでなければ null
create or replace function public._guest_json(u uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g guests; s bigint; w timestamptz; t timestamptz; e timestamptz; fm int;
begin
  select * into g from guests where id = u;
  if not found then return null; end if;
  s := _guest_sent5(u);
  t := _guest_until(u);
  e := coalesce(g.ext_until, g.created_at + interval '31 days');
  select max(month) into fm from tax_returns where user_id = u and declared is not null;
  w := case when coalesce((select value from app_settings where key = 'guest_wait7'), '1') = '1' and _now() < g.created_at + interval '7 days'
            then g.created_at + interval '7 days' end;
  return jsonb_build_object(
    'email', (select email from auth.users where id = u),
    'end', e, 'end_l', to_char(e at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'),
    'ext', g.ext_until is not null, 'ext_days', 31, 'ext_month', fm,
    'can_ext', fm is not null and (g.ext_month is null or fm > g.ext_month),
    'until', t, 'until_l', to_char(t at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'),
    'cap', 40000, 'bet_cap', 100, 'send_cap', 2000, 'sent5', s, 'send_left', greatest(2000 - s, 0),
    'send_from', w, 'send_from_l', case when w is not null then to_char(w at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI') end);
end $$;

-- ゲストの延長：確定申告をした月ごとに1回、消える日を31日のばす（延長すると、5日間来なくても期限までは消えない）
create or replace function public.guest_extend() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); g guests; m int; e timestamptz;
begin
  select * into g from guests where id = u for update;
  if not found then raise exception 'ゲストではありません'; end if;
  select max(month) into m from tax_returns where user_id = u and declared is not null;
  if m is null then raise exception '延長できるのは、確定申告をしたゲストだけです（毎月1日〜15日に、前の月の分を申告できます）'; end if;
  if g.ext_month is not null and m <= g.ext_month then
    raise exception '%月分の申告では、もう延長しました（次の月の分を申告すると、また延長できます）', m % 100;
  end if;
  e := greatest(coalesce(g.ext_until, g.created_at + interval '31 days'), _now()) + interval '31 days';
  update guests set ext_until = e, ext_month = m where id = u;
  return jsonb_build_object('guest', _guest_json(u));
end $$;

-- ゲストの送金の制限（ゲストでなければ何もしない）
create or replace function public._guest_send_check(u uuid, amt bigint) returns void
language plpgsql stable set search_path = public as $$
declare g guests; s bigint;
begin
  select * into g from guests where id = u;
  if not found then return; end if;
  if coalesce((select value from app_settings where key = 'guest_wait7'), '1') = '1' and _now() < g.created_at + interval '7 days' then
    raise exception 'ゲストは、はじめてから7日たつまで送金できません（%から送れます）',
      to_char((g.created_at + interval '7 days') at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI');
  end if;
  s := _guest_sent5(u);
  if s + coalesce(amt, 0) > 2000 then
    raise exception 'ゲストの送金は5日間で2,000 Xまでです（いま送れるのは % Xまで）', _fmt(greatest(2000 - s, 0));
  end if;
end $$;

-- ゲストをはじめる（ログインなしで呼ぶ）。メールの確認はしない（メールも送らない）
create or replace function public.guest_signup(p_email text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare e text := lower(btrim(coalesce(p_email, ''))); pin text := btrim(coalesce(p_pin, '')); v_ip text := _req_ip(); u uuid := gen_random_uuid();
begin
  if char_length(e) > 200 or e !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' then
    raise exception 'メールアドレスが正しくありません';
  end if;
  if pin !~ '^[0-9]{4}$' then raise exception 'パスワードは数字4けたにしてください'; end if;
  perform pg_advisory_xact_lock(7600);
  if exists (select 1 from auth.users where lower(email) = e) then
    raise exception 'このメールアドレスは、もう使われています。上の「ログイン」から入ってください';
  end if;
  if v_ip is not null and (select count(*) from guest_signups where ip = v_ip and at > _now() - interval '1 day') >= 5 then
    raise exception 'この回線からは、きょうはもうゲストを作れません（1日5人まで）。あしたまた試してください';
  end if;
  if (select count(*) from guest_signups where at > _now() - interval '1 hour') >= 60 then
    raise exception 'いまゲストの登録が混みあっています。しばらくしてから試してください';
  end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change,
                          email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated', e, crypt(pin, gen_salt('bf', 10)), now(),
          '{"provider": "email", "providers": ["email"]}'::jsonb,
          jsonb_build_object('sub', u::text, 'email', e, 'email_verified', false, 'phone_verified', false),
          now(), now(), '', '', '', '', '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (u::text, u, jsonb_build_object('sub', u::text, 'email', e, 'email_verified', false, 'phone_verified', false), 'email', now(), now(), now());
  insert into guests(id, created_at, ip) values (u, _now(), v_ip);
  insert into guest_signups(ip, at) values (v_ip, _now());
  return jsonb_build_object('ok', true, 'email', e);
exception when unique_violation then
  raise exception 'このメールアドレスは、もう使われています。上の「ログイン」から入ってください';
end $$;

-- ゲストのメールアドレスを直す（まちがえて入れたとき。本登録の前だけ）
create or replace function public.guest_set_email(p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); e text := lower(btrim(coalesce(p_email, '')));
begin
  if not exists (select 1 from guests where id = u) then raise exception 'ゲストのときだけ直せます'; end if;
  if char_length(e) > 200 or e !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' then
    raise exception 'メールアドレスが正しくありません';
  end if;
  if exists (select 1 from auth.users where lower(email) = e and id <> u) then raise exception 'このメールアドレスは、もう使われています'; end if;
  update auth.users set email = e, updated_at = now(),
         raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('email', e) where id = u;
  update auth.identities set identity_data = identity_data || jsonb_build_object('email', e), updated_at = now()
   where user_id = u and provider = 'email';
  return jsonb_build_object('email', e, 'guest', _guest_json(u));
exception when unique_violation then
  raise exception 'このメールアドレスは、もう使われています';
end $$;

-- 本登録：ゲストがメールのリンクで入った（_mail_seen が記録した）なら、ふつうの登録にする。したら true
create or replace function public._guest_verify(u uuid) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare g guests; mv timestamptz;
begin
  select * into g from guests where id = u for update;
  if not found then return false; end if;
  select mail_verified_at into mv from profiles where id = u;
  if mv is null or mv < g.created_at - interval '1 minute' then return false; end if;
  delete from guests where id = u;
  update profiles set nickname = 'プレイヤー' || substr(nickname, 4) where id = u and nickname ~ '^ゲスト[0-9]{4}$';
  -- 数字4けたのパスワードは使えなくする（6文字以上を決めてもらう）
  update auth.users set encrypted_password = crypt(gen_random_uuid()::text, gen_salt('bf', 10)), updated_at = now(),
         raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || '{"email_verified": true}'::jsonb
   where id = u;
  update auth.identities set identity_data = identity_data || '{"email_verified": true}'::jsonb, updated_at = now()
   where user_id = u and provider = 'email';
  perform _notice(u, '【本登録】メールを確認できたので、本登録になりました（所持金と記録はそのままです）。数字4けたのパスワードは使えなくなりました。設定 → プロフィール で、新しいパスワード（6文字以上）を決めてください。');
  return true;
end $$;

-- ゲストの所持金は40,000 Xまで：こえた分は受け取れない（どこから入ってきても、ここで止める）
create or replace function public._guest_cap_trg() returns trigger
language plpgsql set search_path = public as $$
declare x bigint;
begin
  if not exists (select 1 from guests where id = new.id) then return new; end if;
  x := new.balance - greatest(old.balance, 40000);
  if x > 0 then
    new.balance := new.balance - x;
    insert into guest_overflow(user_id, amount, kind) values (new.id, x, 'cap');
    if not exists (select 1 from notices where user_id = new.id and body like '【ゲスト】所持金は40,000 Xまで%' and created_at > _now() - interval '1 hour') then
      insert into notices(user_id, body)
      values (new.id, format('【ゲスト】所持金は40,000 Xまでです。こえた %s X は受け取れませんでした。本登録すると上限はなくなります（設定 → プロフィール）。', _fmt(x)));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guest_cap on public.profiles;
create trigger profiles_guest_cap before update of balance on public.profiles
  for each row when (new.balance > 40000 and new.balance > old.balance) execute function public._guest_cap_trg();

-- 運営（ID 76705。いなければ最初の管理者）
create or replace function public._sink_user() returns uuid
language sql stable set search_path = public as $$
  select coalesce((select id from profiles where account_no = '76705' and ai is null),
                  (select p.id from profiles p where p.id in (select * from _admin_ids()) order by p.created_at limit 1))
$$;

-- 上限をこえた分・消えたゲストの残りを、運営へ
create or replace function public._guest_flush() returns bigint
language plpgsql set search_path = public as $$
declare s uuid := _sink_user(); t bigint; n int;
begin
  if s is null then return 0; end if;
  with d as (delete from guest_overflow returning amount) select coalesce(sum(amount), 0)::bigint, count(*) into t, n from d;
  if t > 0 then
    perform _give(s, t);
    perform _log(s, 'guest_rest', 0, t, jsonb_build_object('n', n));
  end if;
  return t;
end $$;

-- 期限の切れたゲストを消す（10分ごと）。消した数を返す
create or replace function public._guest_purge() returns int
language plpgsql security definer set search_path = public as $$
declare g record; n int := 0; b bigint;
begin
  if not pg_try_advisory_xact_lock(7601) then return -1; end if;
  for g in select x.id from guests x
            where _guest_until(x.id) <= _now()
            order by x.created_at limit 200 loop
    -- 対戦の部屋（はじまる前・対戦中）にいる・賭けているあいだは、終わるまで待つ
    if exists (select 1 from game_rooms r where r.status in ('waiting', 'playing') and (r.host = g.id or g.id = any(r.seats)))
       or exists (select 1 from game_bets b2 join game_rooms r on r.id = b2.room_id where b2.user_id = g.id and r.status in ('waiting', 'playing')) then
      continue;
    end if;
    begin
      select balance into b from profiles where id = g.id for update;
      if coalesce(b, 0) > 0 then insert into guest_overflow(user_id, amount, kind) values (g.id, b, 'left'); end if;
      delete from auth.users where id = g.id;      -- プロフィール・記録なども、いっしょに消える
      n := n + 1;
    exception when others then
      raise warning 'guest purge failed (%): %', g.id, sqlerrm;
    end;
  end loop;
  perform _guest_flush();
  delete from guest_signups where at < _now() - interval '3 days';
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-guest', '*/10 * * * *', 'select public._guest_purge()');
  end if;
end $$;

-- =====================================================================
-- 市区町村バトル（賭けありの部屋）
--   サイトのアカウントで遊ぶ。ルールの判定・CPUの手・時間切れ・決着は、サーバー（Edge Function「battle」）がする
--   部屋は game_rooms（game = 'battle'）。席は seats（長さ＝人数。空きは null、はじまると空きはCPU）
--   state：cfg（設定）・ph（lobby / play / over）・g・plan（開始の配置）・mv（手の列）・n（手数）・turn・round
--          ck（持ち時間：b＝席ごとの残り ms・p＝時計が動いている席・t0＝その番がはじまった時刻 ms）・due（人の締め切り ms）
--          cpu（CPUの番が残っている）・tok（席の印）・rx（リアクション）・res（結果）・eng（エンジンの版）
--   賭け金：入るときに払う（CPUは賭けない）。勝った人（紅白戦は勝った組の人。脱落した味方もふくむ）で山分け。もうけの5%は国庫
--     賭けている人が1人だけ・賭けている人がだれも勝たなかった（CPUの勝ち）・引き分けのときは、全部返す
--   観戦の賭け：対局していない人が、勝つ人（紅白戦は組）に賭ける（1巡目のあいだ・1つだけ）。山分け・国庫5%
--     引き分け・勝った側に賭けがない・片方にしか賭けがないときは全部返す
--   持ち時間か秒読みは必ずつける。時間が切れたらCPUがかわりに指す（もとのルールのまま）
--   始まらない部屋は2時間で片づける。12時間たっても終わらない対局は、賭けを返して終わりにする
-- =====================================================================
create table if not exists public.bt_tickets (
  ticket  text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  exp     timestamptz not null
);
create index if not exists bt_tickets_user_idx on public.bt_tickets(user_id);
alter table public.bt_tickets enable row level security;
revoke all on public.bt_tickets from anon, authenticated;
insert into public.app_settings values ('bt_key', replace(gen_random_uuid()::text, '-', '')) on conflict (key) do nothing;

-- 席の印（部屋とユーザーで決まる。部屋の中だけで使う）
create or replace function public._bt_tok(rid bigint, u uuid) returns text
language sql immutable as $$ select left(md5(rid::text || ':' || u::text || ':kz-battle'), 10) $$;

-- 画面（battle/）から：サーバーに手を送るためのチケット（12時間）。名前・所持金もいっしょに返す
create or replace function public.bt_ticket() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); t text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not exists (select 1 from profiles where id = u) then perform ensure_profile(); end if;
  delete from bt_tickets where user_id = u and (exp < now() or ticket in (select ticket from bt_tickets where user_id = u order by exp desc offset 4));
  insert into bt_tickets values (t, u, now() + interval '12 hours');
  return (select jsonb_build_object('ticket', t, 'nick', nickname, 'balance', balance, 'id', account_no, 'guest', _is_guest(u)) from profiles where id = u);
end $$;

-- Edge Function から：チケット → ユーザー
create or replace function public._bt_auth(p_ticket text) returns uuid
language plpgsql stable set search_path = public as $$
declare u uuid; bu timestamptz;
begin
  select user_id into u from bt_tickets where ticket = coalesce(p_ticket, '') and exp > now();
  if u is null then raise exception 'ログインしなおしてください（画面を読み込み直してください）'; end if;
  select banned_until into bu from profiles where id = u;
  if bu is not null and bu > _now() then raise exception '利用停止中です（%まで）', to_char(bu at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'); end if;
  return u;
end $$;

-- 部屋の一覧の1行
create or replace function public._bt_row(g game_rooms, u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', g.id, 'title', g.title, 'host', (select nickname from profiles where id = g.host), 'status', g.status,
    'p', g.state->'cfg'->>'p', 'r', g.state->'cfg'->>'r', 'n', g.max_seats, 'f', (select count(*) from unnest(g.seats) x where x is not null),
    'tm', coalesce((g.state->'cfg'->>'tm')::int, 0), 'tb', coalesce((g.state->'cfg'->>'tb')::int, 0), 'by', coalesce((g.state->'cfg'->>'by')::int, 0),
    'sp', coalesce((g.state->'cfg'->>'sp')::int, 0), 'stake', g.stake, 'bets', g.bets_on, 'mine', u = any(g.seats),
    'round', (g.state->>'round')::int, 'at', to_char(coalesce(g.started_at, g.created_at) at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'),
    'res', g.state->'res')
$$;

-- 部屋の一覧（募集中・対局中・自分が終わった部屋）
create or replace function public.bt_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g();
begin
  return jsonb_build_object(
    'open', (select coalesce(jsonb_agg(_bt_row(g, u) order by g.id desc), '[]'::jsonb) from (select * from game_rooms where game = 'battle' and status = 'waiting' order by id desc limit 30) g),
    'live', (select coalesce(jsonb_agg(_bt_row(g, u) order by g.id desc), '[]'::jsonb) from (select * from game_rooms where game = 'battle' and status = 'playing' order by id desc limit 30) g),
    'done', (select coalesce(jsonb_agg(_bt_row(g, u) order by g.finished_at desc), '[]'::jsonb) from (
               select * from game_rooms where game = 'battle' and status in ('finished', 'canceled')
                  and (u = any(seats) or id in (select room_id from game_bets where user_id = u)) order by finished_at desc nulls last limit 10) g),
    'balance', _bal(u));
end $$;

-- 部屋の今（画面が1〜2秒ごとに読む）。h はもとの「ホストの知らせ」と同じ形
create or replace function public.bt_state(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; st jsonb; n int; me int; nowms bigint := floor(extract(epoch from _now()) * 1000)::bigint;
        seats jsonb; h jsonb; tm boolean; rx jsonb;
begin
  select * into r from game_rooms where id = p_room and game = 'battle';
  if not found then raise exception 'その部屋は見つかりません'; end if;
  st := r.state; n := r.max_seats; tm := coalesce((st->'cfg'->>'tm')::int, 0) = 1;
  me := array_position(r.seats, u) - 1;
  seats := (select jsonb_agg(case
      when r.seats[i] is not null then jsonb_build_object('k', case when r.seats[i] = r.host then 'host' else 'guest' end,
                                                          'n', (select nickname from profiles where id = r.seats[i]), 't', st->'tok'->>(i - 1))
      when r.status <> 'waiting' then jsonb_build_object('k', 'cpu', 'n', 'CPU', 't', '')
      end order by i) from generate_series(1, n) i);
  h := jsonb_build_object('v', 12, 'role', 'host', 'code', r.id::text, 'nick', (select nickname from profiles where id = r.host), 'pub', 0,
         'ph', coalesce(st->>'ph', 'lobby'), 'g', coalesce((st->>'g')::int, 1), 'ep', 0, 'hs', 0, 'cfg', st->'cfg', 'seats', seats,
         'plan', st->'plan', 'mv', coalesce(st->>'mv', ''));
  if st->>'ph' = 'play' and coalesce((st->'ck'->>'p')::int, -1) >= 0 then
    h := h || jsonb_build_object('ck', jsonb_build_object('n', coalesce((st->>'n')::int, 0), 'p', (st->'ck'->>'p')::int, 'b', st->'ck'->'b',
                                                          'e', greatest(0, nowms - (st->'ck'->>'t0')::bigint)));
  end if;
  rx := (select coalesce(jsonb_agg(e || jsonb_build_object('ag', nowms - (e->>'t')::bigint)), '[]'::jsonb)
           from jsonb_array_elements(coalesce(st->'rx', '[]'::jsonb)) e where (e->>'t')::bigint > nowms - 10000);
  if jsonb_array_length(rx) > 0 then h := h || jsonb_build_object('rx', rx); end if;
  return jsonb_build_object('h', h,
    'room', jsonb_build_object('id', r.id, 'status', r.status, 'title', r.title, 'stake', r.stake, 'bets_on', r.bets_on, 'host', r.host = u,
                               'round', (st->>'round')::int, 'cpu', coalesce((st->>'cpu')::boolean, false), 'due', (st->>'due')::bigint, 'now', nowms),
    'me', case when me is not null then st->'tok'->>me end, 'seat', me,
    'bets', jsonb_build_object('open', r.status = 'playing' and r.bets_on and me is null and coalesce((st->>'round')::int, 0) <= 1,
              'side', case when tm then 'team' else 'seat' end,
              'pools', (select coalesce(jsonb_object_agg(seat, s), '{}'::jsonb) from (select seat, sum(amount) s from game_bets where room_id = r.id group by seat) x),
              'mine', (select coalesce(jsonb_agg(jsonb_build_object('side', seat, 'amount', amount, 'payout', payout) order by id), '[]'::jsonb)
                         from game_bets where room_id = r.id and user_id = u)),
    'stake', (select jsonb_build_object('amount', amount, 'payout', payout) from game_stakes where room_id = r.id and user_id = u),
    'res', st->'res', 'balance', _bal(u));
end $$;

-- 部屋に入る（はじまる前だけ。賭けありなら賭け金を払う）
create or replace function public.bt_join(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; i int;
begin
  select * into r from game_rooms where id = p_room and game = 'battle' for update;
  if not found or r.status <> 'waiting' then raise exception 'この部屋にはもう入れません'; end if;
  if u = any(r.seats) then return bt_state(p_room); end if;
  if (select count(*) from game_rooms where game = 'battle' and u = any(seats) and status in ('waiting', 'playing')) >= 3 then
    raise exception '市区町村バトルで参加中の部屋は3つまでです';
  end if;
  i := array_position(r.seats, null);
  if i is null then raise exception '席がいっぱいです'; end if;
  perform _room_stake(r, u);
  r.seats[i] := u;
  update game_rooms set seats = r.seats, state = jsonb_set(state, array['tok', (i - 1)::text], to_jsonb(_bt_tok(r.id, u))), act_at = _now() where id = r.id;
  perform _notice(r.host, format('【対戦】%s さんが市区町村バトルの部屋 #%s に入りました（%s/%s人）。', (select nickname from profiles where id = u), r.id,
                  (select count(*) from unnest(r.seats) x where x is not null), r.max_seats));
  return bt_state(p_room);
end $$;

-- 部屋を出る（はじまる前だけ。賭け金は返す。主催が出ると部屋はなくなる）。対局中は出られない（時間切れのあとはCPUが指す）
create or replace function public.bt_leave(p_room bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; i int; b record;
begin
  select * into r from game_rooms where id = p_room and game = 'battle' for update;
  if not found or r.status <> 'waiting' then return jsonb_build_object('ok', true); end if;
  if r.host = u then perform _room_cancel(r.id, true); return jsonb_build_object('ok', true, 'canceled', true); end if;
  i := array_position(r.seats, u);
  if i is null then return jsonb_build_object('ok', true); end if;
  for b in select * from game_stakes where room_id = r.id and user_id = u and payout is null loop
    update profiles set balance = balance + b.amount where id = u;
    perform _log(u, 'game_stake', b.amount, b.amount, jsonb_build_object('room', r.id, 'game', 'battle', 'refund', true));
  end loop;
  delete from game_stakes where room_id = r.id and user_id = u;
  r.seats[i] := null;
  update game_rooms set seats = r.seats, state = jsonb_set(state, array['tok', (i - 1)::text], '""'::jsonb), act_at = _now() where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- 主催：はじまる前に、組わけ（紅白戦）と順番（自分で決める）を変える
create or replace function public.bt_lobby_set(p_room bigint, p_tt text, p_os text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; c jsonb; n int; d int[];
begin
  select * into r from game_rooms where id = p_room and game = 'battle' for update;
  if not found or r.status <> 'waiting' then raise exception 'はじまる前だけ変えられます'; end if;
  if r.host <> u then raise exception '部屋をつくった人だけ変えられます'; end if;
  c := r.state->'cfg'; n := (c->>'n')::int;
  if p_tt is not null and (c->>'tm')::int = 1 then
    if char_length(p_tt) <> n or p_tt !~ '^[01]+$' then raise exception '組わけが正しくありません'; end if;
    c := jsonb_set(c, '{tt}', to_jsonb(p_tt));
  end if;
  if p_os is not null and c->>'om' = 's' then
    if char_length(p_os) <> n or p_os !~ '^[0-9a-z]+$' then raise exception '順番が正しくありません'; end if;
    d := array(select (case when ch ~ '[0-9]' then ascii(ch) - 48 else ascii(ch) - 87 end) from regexp_split_to_table(p_os, '') ch);
    if exists (select 1 from unnest(d) x where x < 0 or x >= n) or (select count(distinct x) from unnest(d) x) <> n then raise exception '順番が正しくありません'; end if;
    c := jsonb_set(c, '{os}', to_jsonb(p_os));
  end if;
  update game_rooms set state = jsonb_set(state, '{cfg}', c) where id = r.id;
  return bt_state(p_room);
end $$;

-- 観戦の賭け（対局していない人。1巡目のあいだ。1人（1組）にだけ）
create or replace function public.bt_bet(p_room bigint, p_side int, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; made timestamptz; tm boolean; n int;
begin
  select * into r from game_rooms where id = p_room and game = 'battle' for update;
  if not found or r.status <> 'playing' then raise exception '対局中の部屋だけ賭けられます'; end if;
  if not r.bets_on then raise exception 'この部屋は観戦の賭けなしです'; end if;
  if u = any(r.seats) then raise exception '対局している本人は賭けられません'; end if;
  if coalesce((r.state->>'round')::int, 0) > 1 then raise exception '賭けは1巡目のあいだだけです'; end if;
  tm := coalesce((r.state->'cfg'->>'tm')::int, 0) = 1; n := r.max_seats;
  if p_side is null or (tm and p_side not in (0, 1)) or (not tm and (p_side < 0 or p_side >= n)) then raise exception '賭ける相手をえらんでください'; end if;
  if exists (select 1 from game_bets where room_id = r.id and user_id = u and seat <> p_side) then
    if tm then raise exception 'ちがう組には賭けられません（1つの組だけ）'; end if;
    raise exception 'ちがう人には賭けられません（1人だけ）';
  end if;
  if p_amount is null or p_amount < 1 then raise exception '1 X以上にしてください'; end if;
  select coalesce(ok7_at - interval '7 days', created_at) into made from profiles where id = u;
  if _now() < made + interval '7 days' then raise exception '観戦の賭けは、登録から7日たってからです（%から）', _dlabel(made + interval '7 days'); end if;
  if _debt(u) > 0 then raise exception '税金の滞納があるので賭けられません'; end if;
  perform _take(u, p_amount);
  insert into game_bets(room_id, user_id, seat, amount, at) values (r.id, u, p_side, p_amount, _now());
  return bt_state(p_room);
end $$;

-- リアクション（1.5秒に1回。10秒で消える）
create or replace function public.bt_react(p_room bigint, p_k int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r game_rooms; i int; o text; nowms bigint := floor(extract(epoch from _now()) * 1000)::bigint; rx jsonb;
begin
  if p_k is null or p_k < 0 or p_k > 4 then raise exception 'えらべないリアクションです'; end if;
  select * into r from game_rooms where id = p_room and game = 'battle' for update;
  if not found or r.status <> 'playing' then return jsonb_build_object('ok', false); end if;
  i := array_position(r.seats, u);
  o := coalesce(case when i is not null then r.state->'tok'->>(i - 1) end, _bt_tok(r.id, u));
  rx := coalesce(r.state->'rx', '[]'::jsonb);
  if exists (select 1 from jsonb_array_elements(rx) e where e->>'o' = o and (e->>'t')::bigint > nowms - 1500) then return jsonb_build_object('ok', false); end if;
  rx := (select coalesce(jsonb_agg(e order by (e->>'t')::bigint), '[]'::jsonb) from jsonb_array_elements(rx) e where (e->>'t')::bigint > nowms - 10000);
  rx := rx || jsonb_build_array(jsonb_build_object('s', coalesce(i - 1, -1), 'k', p_k, 'o', o, 'n', nowms, 't', nowms)
                                || case when i is null then jsonb_build_object('nm', (select nickname from profiles where id = u)) else '{}'::jsonb end);
  if jsonb_array_length(rx) > 5 then rx := (select jsonb_agg(e) from (select e from jsonb_array_elements(rx) with ordinality x(e, o) order by o offset jsonb_array_length(rx) - 5) y); end if;
  update game_rooms set state = jsonb_set(state, '{rx}', rx) where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- Edge Function から：部屋をつくる（設定はサーバーで確かめたもの）。主催は席0
create or replace function public._bt_create(u uuid, p_cfg jsonb, p_title text, p_stake bigint, p_bets boolean, p_eng text) returns bigint
language plpgsql set search_path = public as $$
declare n int := (p_cfg->>'n')::int; r game_rooms;
begin
  if n is null or n < 2 or n > 16 then raise exception '人数が正しくありません'; end if;
  if (select count(*) from game_rooms where host = u and game = 'battle' and status = 'waiting') >= 1 then
    raise exception '募集中の部屋がもうあります（1つまで）';
  end if;
  if (select count(*) from game_rooms where game = 'battle' and u = any(seats) and status in ('waiting', 'playing')) >= 3 then
    raise exception '市区町村バトルで参加中の部屋は3つまでです';
  end if;
  if p_stake is null or p_stake < 0 or p_stake > 1000000 then raise exception '賭け金は0〜1,000,000 Xです'; end if;
  insert into game_rooms(game, title, host, seats, status, max_seats, stake, stake_mode, bets_on, time_ms, state, created_at, act_at)
  values ('battle', left(btrim(coalesce(p_title, '')), 30), u, array_fill(null::uuid, array[n]), 'waiting', n, p_stake, 'all', coalesce(p_bets, true), 0,
          jsonb_build_object('cfg', p_cfg, 'ph', 'lobby', 'g', 1, 'mv', '', 'n', 0, 'tok', to_jsonb(array_fill(''::text, array[n])), 'rx', '[]'::jsonb, 'eng', p_eng),
          _now(), _now())
  returning * into r;
  r.seats[1] := u;
  update game_rooms set seats = r.seats, state = jsonb_set(state, '{tok,0}', to_jsonb(_bt_tok(r.id, u))) where id = r.id;
  perform _room_stake(r, u);
  return r.id;
end $$;

-- Edge Function から：はじめる（開始の配置はサーバーで決めた state）。空いた席はCPU。賭けている人が1人だけなら賭け金は返す
create or replace function public._bt_start(rid bigint, by_u uuid, p_state jsonb) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; cs int[] := '{}'; i int; s record;
begin
  select * into r from game_rooms where id = rid for update;
  if not found or r.status <> 'waiting' then raise exception 'この部屋はもう始まっています'; end if;
  if r.host <> by_u then raise exception '部屋をつくった人だけ始められます'; end if;
  for i in 1..r.max_seats loop if r.seats[i] is null then cs := cs || (i - 1); end if; end loop;
  if (select count(*) from game_stakes where room_id = rid) <= 1 then
    for s in select * from game_stakes where room_id = rid loop
      update profiles set balance = balance + s.amount where id = s.user_id;
      perform _log(s.user_id, 'game_stake', s.amount, s.amount, jsonb_build_object('room', rid, 'game', 'battle', 'refund', true));
    end loop;
    delete from game_stakes where room_id = rid;
  end if;
  update game_rooms set status = 'playing', started_at = _now(), act_at = _now(), cpu = cs, state = p_state where id = rid;
  for i in 1..r.max_seats loop
    if r.seats[i] is not null and r.seats[i] <> by_u then
      perform _notice(r.seats[i], format('【対戦】市区町村バトルの部屋 #%s が始まりました。市区町村バトルの画面から入れます。', rid));
    end if;
  end loop;
end $$;

-- Edge Function から：決着の精算（p_win：勝った席。引き分けは空）
create or replace function public._bt_settle(rid bigint, p_win int[], p_why text, p_res jsonb) returns void
language plpgsql set search_path = public as $$
declare r game_rooms; s record; b record; ns int; nw int; lsum bigint := 0; share bigint; rem bigint; gain bigint; cut bigint; tcut bigint := 0;
        pay bigint; k int := 0; tm boolean; wcode int; wside int; pool bigint; win_pool bigint; paid bigint := 0; last_id bigint;
begin
  select * into r from game_rooms where id = rid for update;
  if not found or r.status <> 'playing' then return; end if;
  wcode := (p_res->>'win')::int; tm := coalesce((r.state->'cfg'->>'tm')::int, 0) = 1;
  update game_rooms set status = 'finished', finished_at = _now(), winner = wcode, reason = p_why,
         state = jsonb_set(jsonb_set(state, '{res}', p_res), '{ph}', '"over"') where id = rid;
  -- 賭け金：勝った人で山分け
  select count(*), count(*) filter (where array_position(r.seats, user_id) - 1 = any(coalesce(p_win, '{}'))) into ns, nw
    from game_stakes where room_id = rid and payout is null;
  if ns >= 2 and nw >= 1 then
    select coalesce(sum(amount), 0) into lsum from game_stakes
     where room_id = rid and payout is null and not (array_position(r.seats, user_id) - 1 = any(coalesce(p_win, '{}')));
    share := lsum / nw; rem := lsum - share * nw;
    for s in select * from game_stakes where room_id = rid and payout is null order by array_position(r.seats, user_id) loop
      if array_position(r.seats, s.user_id) - 1 = any(p_win) then
        gain := share + case when k = 0 then rem else 0 end; k := k + 1;
        cut := floor(gain * 0.05); tcut := tcut + cut;
        pay := s.amount + gain - cut;
        perform _give(s.user_id, pay);
      else
        pay := 0;
      end if;
      update game_stakes set payout = pay where room_id = rid and user_id = s.user_id;
      perform _log(s.user_id, 'game_stake', s.amount, pay, jsonb_build_object('room', rid, 'game', 'battle', 'win', pay > 0));
    end loop;
  else
    for s in select * from game_stakes where room_id = rid and payout is null loop
      update profiles set balance = balance + s.amount where id = s.user_id;
      update game_stakes set payout = s.amount where room_id = rid and user_id = s.user_id;
      perform _log(s.user_id, 'game_stake', s.amount, s.amount, jsonb_build_object('room', rid, 'game', 'battle', 'refund', true));
    end loop;
  end if;
  -- 観戦の賭け：勝った人（組）に賭けた人で山分け
  wside := case when wcode is null or wcode = 99 then null when tm then wcode - 100 else wcode end;
  pool := coalesce((select sum(amount) from game_bets where room_id = rid and payout is null), 0);
  win_pool := coalesce((select sum(amount) from game_bets where room_id = rid and payout is null and seat = wside), 0);
  if pool > 0 then
    if wside is null or win_pool = 0 or win_pool = pool then
      for b in select * from game_bets where room_id = rid and payout is null loop
        update profiles set balance = balance + b.amount where id = b.user_id;
        update game_bets set payout = b.amount where id = b.id;
        perform _log(b.user_id, 'game_bet', b.amount, b.amount, jsonb_build_object('room', rid, 'game', 'battle', 'refund', true));
      end loop;
    else
      cut := floor(pool * 0.05); tcut := tcut + cut;
      select max(id) into last_id from game_bets where room_id = rid and payout is null and seat = wside;
      for b in select * from game_bets where room_id = rid and payout is null order by id loop
        if b.seat = wside then
          pay := floor((pool - cut)::numeric * b.amount / win_pool);
          if b.id = last_id then pay := pay + (pool - cut - paid - pay); end if;
          paid := paid + pay;
          perform _give(b.user_id, pay);
        else
          pay := 0;
        end if;
        update game_bets set payout = pay where id = b.id;
        perform _log(b.user_id, 'game_bet', b.amount, pay, jsonb_build_object('room', rid, 'game', 'battle'));
      end loop;
    end if;
  end if;
  if tcut > 0 then update treasury set balance = balance + tcut, casino_total = casino_total + tcut where id = 1; end if;
end $$;

-- サーバー（Edge Function）を呼ぶための拡張（pg_net）。使えないところでは、片づけだけする
do $$
begin
  begin
    create extension if not exists pg_net with schema extensions;
  exception when others then
    raise notice 'pg_net は使えません（市区町村バトルの時間切れは、画面からだけ進めます）';
  end;
end $$;

-- 毎分：始まらない部屋・長すぎる対局を片づけ、時間切れやCPUの番が残っている部屋をサーバーに進めさせる
create or replace function public._bt_cron() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; url text := (select value from app_settings where key = 'bt_url'); key text := (select value from app_settings where key = 'bt_key');
        nowms bigint := floor(extract(epoch from _now()) * 1000)::bigint;
begin
  for r in select id from game_rooms where game = 'battle' and status = 'waiting' and created_at < _now() - interval '2 hours' for update skip locked loop
    perform _room_cancel(r.id, true);
  end loop;
  for r in select id from game_rooms where game = 'battle' and status = 'playing' and started_at < _now() - interval '12 hours' for update skip locked loop
    perform _room_cancel(r.id);
    update game_rooms set reason = '時間がかかりすぎたので終わり（賭けは返しました）' where id = r.id;
  end loop;
  if url is null or not exists (select 1 from pg_namespace where nspname = 'net') then return 0; end if;
  for r in select id from game_rooms where game = 'battle' and status = 'playing'
              and (coalesce((state->>'cpu')::boolean, false) or coalesce((state->>'due')::bigint, nowms + 1) < nowms - 3000)
              and coalesce(act_at, started_at) < now() - interval '15 seconds' order by id limit 20 loop
    execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 8000)'
      using url, jsonb_build_object('a', 'tick', 'room', r.id, 'key', key), jsonb_build_object('Content-Type', 'application/json', 'x-region', 'ap-northeast-1');
    n := n + 1;
  end loop;
  return n;
end $$;
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-battle', '* * * * *', 'select public._bt_cron()');
  end if;
end $$;

-- =====================================================================
-- 風の芽ジャンボ（週1回の宝くじ）
--   くじは「組」（01〜10）と「番号」（0000〜9999）。1枚 100 X。1回の抽せんで1人1,000枚まで（ゲストは1枚ずつ）
--   買い方：1枚（番号はおまかせ）・バラ10枚（下1けたが0〜9に1枚ずつ）・連番10枚（同じ組で番号が続く）
--   抽せん：毎週日曜 21:30（日本時間）。そこで締め切り、すぐ次の回の発売がはじまる
--   当せん（1枚は上の等級だけ）：
--     1等：組と番号が全部一致 → ジャックポット（だれも当たらなければ次の回に持ちこし。売上の10%を積み立て。当たったら次の回は100万 X から）
--     1等の前後賞：1等と同じ組で、番号が1つちがい → 100万 X
--     1等の組違い賞：番号が1等と同じで、組がちがう → 10万 X
--     2等：下3けたが一致 → 1万 X ／ 3等：下2けたが一致 → 1,000 X ／ 4等：下1けたが一致 → 100 X
--   当せん金は自動で入る（非課税）。売上と払いもどしは国庫（カジノのもうけと同じ）
-- =====================================================================
create table if not exists public.lot_draws (
  id        serial primary key,
  draw_at   timestamptz not null,
  status    text not null default 'open',          -- open / drawn
  jackpot   bigint not null default 0,             -- この回の1等の額（持ちこし＋積み立て）
  sales     int not null default 0,                -- 売れた枚数
  win       jsonb,                                 -- 当せん番号 {g, n, d3, d2, d1}
  winners   jsonb,                                 -- 等級ごとの本数
  hit       boolean,                               -- 1等が出たか
  drawn_at  timestamptz
);
create table if not exists public.lot_tickets (
  id       bigserial primary key,
  draw_id  int not null references public.lot_draws(id) on delete cascade,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  grp      int not null,                           -- 組 1〜10
  num      int not null,                           -- 番号 0〜9999
  kind     text not null,                          -- one / bara / renban
  pack     bigint not null,                        -- いっしょに買った束
  tier     int,                                    -- 0 はずれ・1 1等・11 前後賞・12 組違い賞・2・3・4
  payout   bigint,
  at       timestamptz not null default now(),
  unique (draw_id, grp, num)
);
create index if not exists lot_tickets_user_idx on public.lot_tickets(draw_id, user_id);
create sequence if not exists public.lot_pack_seq;
alter table public.lot_draws enable row level security;
alter table public.lot_tickets enable row level security;
revoke all on public.lot_draws, public.lot_tickets from anon, authenticated;

create or replace function public._lot_seed() returns bigint language sql immutable as $$ select 1000000::bigint $$;
-- 等級ごとの当せん金（1等はジャックポット）
create or replace function public._lot_prize(t int) returns bigint language sql immutable as $$
  select case t when 11 then 1000000 when 12 then 100000 when 2 then 10000 when 3 then 1000 when 4 then 100 else 0 end::bigint $$;
create or replace function public._lot_tier_name(t int) returns text language sql immutable as $$
  select case t when 1 then '1等' when 11 then '1等の前後賞' when 12 then '1等の組違い賞' when 2 then '2等' when 3 then '3等' when 4 then '4等' else 'はずれ' end $$;
-- 0〜n-1 の乱数（gen_random_uuid の乱数を使う）
create or replace function public._rnd(n int) returns int language sql volatile as $$
  select (('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint % n)::int $$;
-- after のあとの、日曜 21:30（日本時間）
create or replace function public._lot_next_at(after timestamptz) returns timestamptz language sql stable as $$
  select case when x > after then x else x + interval '7 days' end
    from (select ((date_trunc('week', after at time zone 'Asia/Tokyo') + interval '6 days 21 hours 30 minutes') at time zone 'Asia/Tokyo') x) z $$;

-- 毎分：抽せんの時刻をすぎた回を抽せんして、次の回をはじめる（まだ1回もなければ第1回をつくる）
create or replace function public._lot_tick() returns text
language plpgsql security definer set search_path = public as $$
declare d lot_draws;
begin
  if not pg_try_advisory_xact_lock(7700) then return 'busy'; end if;
  select * into d from lot_draws where status = 'open' order by id desc limit 1;
  if not found then
    insert into lot_draws(draw_at, jackpot) values (_lot_next_at(_now()), _lot_seed());
    return 'first';
  end if;
  if d.draw_at > _now() then return 'wait'; end if;
  perform _lot_draw(d.id);
  return 'drawn';
end $$;

-- 抽せん
create or replace function public._lot_draw(did int) returns void
language plpgsql set search_path = public as $$
declare d lot_draws; g int := 1 + _rnd(10); n int := _rnd(10000); d3 int := _rnd(1000); d2 int := _rnd(100); d1 int := _rnd(10);
        r record; v_hit boolean; w jsonb; lines text;
begin
  select * into d from lot_draws where id = did for update;
  if not found or d.status <> 'open' then return; end if;
  update lot_tickets t set tier = case
      when t.grp = g and t.num = n then 1
      when t.grp = g and (t.num = (n + 1) % 10000 or t.num = (n + 9999) % 10000) then 11
      when t.num = n then 12
      when t.num % 1000 = d3 then 2
      when t.num % 100 = d2 then 3
      when t.num % 10 = d1 then 4
      else 0 end
   where t.draw_id = did;
  update lot_tickets set payout = case when tier = 1 then d.jackpot else _lot_prize(tier) end where draw_id = did;
  v_hit := exists (select 1 from lot_tickets where draw_id = did and tier = 1);
  w := (select jsonb_object_agg(tier, c) from (select tier, count(*) c from lot_tickets where draw_id = did and tier > 0 group by tier) x);
  update lot_draws set status = 'drawn', drawn_at = _now(), hit = v_hit, winners = coalesce(w, '{}'::jsonb),
         win = jsonb_build_object('g', g, 'n', n, 'd3', d3, 'd2', d2, 'd1', d1) where id = did;
  -- 当せん金を入れて（人ごとにまとめて）、買った人みんなに知らせる
  for r in select user_id, count(*) cnt, sum(payout)::bigint s, count(*) filter (where tier > 0) k
             from lot_tickets where draw_id = did group by user_id loop
    if r.s > 0 then
      perform _give(r.user_id, r.s);
      perform _log(r.user_id, 'lottery', 0, r.s, jsonb_build_object('draw', did, 'wins', r.k));
      select string_agg(format('%s %s本', _lot_tier_name(tier), c), '・' order by case tier when 1 then 0 when 11 then 1 when 12 then 2 else tier + 1 end) into lines
        from (select tier, count(*) c from lot_tickets where draw_id = did and user_id = r.user_id and tier > 0 group by tier) z;
      perform _notice_l(r.user_id, format('【風の芽ジャンボ】第%s回の抽せん：当せんしました！ 合計 %s X（%s）。当せん金はもう入っています。', did, _fmt(r.s), lines),
                        '{"go":"lot"}'::jsonb, null);
    else
      perform _notice_l(r.user_id, format('【風の芽ジャンボ】第%s回の抽せん：あなたのくじ %s枚は、残念ながらはずれでした。当せん番号は「風の芽ジャンボ」の画面で見られます。', did, r.cnt),
                        '{"go":"lot"}'::jsonb, null);
    end if;
  end loop;
  -- 次の回（1等が出たら100万 X から。出なければ持ちこし）
  insert into lot_draws(draw_at, jackpot) values (_lot_next_at(greatest(_now(), d.draw_at)), case when v_hit then _lot_seed() else d.jackpot end);
  -- 新聞に当せん番号をのせる（名前は出さない）
  begin
    perform _ai_article(format('【くじ】風の芽ジャンボ 第%s回の当せん番号', did),
      format('風の芽ジャンボの第%s回の抽せんが、%sにおこなわれた。', did, to_char(d.draw_at at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI')) || E'\n\n'
      || format('1等（%s X）　%s組 %s番', _fmt(d.jackpot), lpad(g::text, 2, '0'), lpad(n::text, 4, '0')) || E'\n'
      || format('1等の前後賞（%s X）　%s組 %s番・%s番', _fmt(_lot_prize(11)), lpad(g::text, 2, '0'), lpad(((n + 9999) % 10000)::text, 4, '0'), lpad(((n + 1) % 10000)::text, 4, '0')) || E'\n'
      || format('1等の組違い賞（%s X）　ほかの組の %s番', _fmt(_lot_prize(12)), lpad(n::text, 4, '0')) || E'\n'
      || format('2等（%s X）　下3けた %s', _fmt(_lot_prize(2)), lpad(d3::text, 3, '0')) || E'\n'
      || format('3等（%s X）　下2けた %s', _fmt(_lot_prize(3)), lpad(d2::text, 2, '0')) || E'\n'
      || format('4等（%s X）　下1けた %s', _fmt(_lot_prize(4)), d1) || E'\n\n'
      || case when v_hit then format('今回は1等が出た。次の回のジャックポットは %s X から積み立てがはじまる。', _fmt(_lot_seed()))
              else format('今回は1等が出なかったため、%s X は次の回に持ちこされる。', _fmt(d.jackpot)) end
      || E'\n\n' || 'くじは遊戯 → 風の芽製作所 → 風の芽ジャンボ で買える（1枚 100 X。毎週日曜 21:30 に抽せん）。', '生活部');
  exception when others then null;
  end;
end $$;

-- 買う（p_kind：one 1枚 / bara バラ10枚 / renban 連番10枚。p_sets：何回分（1〜100））
create or replace function public.lot_buy(p_kind text, p_sets int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); d lot_draws; k int := greatest(coalesce(p_sets, 1), 1); cnt int; mine int; cost bigint; pk bigint;
        s int; i int; g int; n int; base int; tries int;
begin
  if p_kind not in ('one', 'bara', 'renban') then raise exception '買い方をえらんでください'; end if;
  if k > 100 then raise exception '一度に買えるのは100回分までです'; end if;
  perform _lot_tick();
  select * into d from lot_draws where status = 'open' order by id desc limit 1 for update;
  if not found or d.draw_at <= _now() then raise exception 'いま抽せん中です。少ししてから買ってください'; end if;
  cnt := case when p_kind = 'one' then k else k * 10 end;
  select count(*) into mine from lot_tickets where draw_id = d.id and user_id = u;
  if mine + cnt > 1000 then raise exception '1回の抽せんで買えるのは1人1,000枚までです（あと %枚）', greatest(1000 - mine, 0); end if;
  cost := cnt * 100;
  perform _take(u, cost);
  if p_kind = 'one' then                -- 1枚ずつ：まとめて1つの束
    pk := nextval('lot_pack_seq');
    for s in 1..k loop
      tries := 0;
      loop
        tries := tries + 1; g := 1 + _rnd(10); n := _rnd(10000);
        exit when not exists (select 1 from lot_tickets where draw_id = d.id and grp = g and num = n);
        if tries > 60 then raise exception 'くじが売り切れに近いので、買えません'; end if;
      end loop;
      insert into lot_tickets(draw_id, user_id, grp, num, kind, pack, at) values (d.id, u, g, n, 'one', pk, _now());
    end loop;
  else                                   -- バラ・連番：10枚ごとに1つの束
    for s in 1..k loop
      pk := nextval('lot_pack_seq');
      tries := 0;
      if p_kind = 'renban' then
        loop
          tries := tries + 1; g := 1 + _rnd(10); base := _rnd(1000) * 10;
          exit when not exists (select 1 from lot_tickets where draw_id = d.id and grp = g and num between base and base + 9);
          if tries > 60 then raise exception 'くじが売り切れに近いので、連番では買えません'; end if;
        end loop;
        insert into lot_tickets(draw_id, user_id, grp, num, kind, pack, at) select d.id, u, g, base + j, 'renban', pk, _now() from generate_series(0, 9) j;
      else
        for i in 0..9 loop
          tries := 0;
          loop
            tries := tries + 1; g := 1 + _rnd(10); n := _rnd(1000) * 10 + i;
            exit when not exists (select 1 from lot_tickets where draw_id = d.id and grp = g and num = n);
            if tries > 60 then raise exception 'くじが売り切れに近いので、買えません'; end if;
          end loop;
          insert into lot_tickets(draw_id, user_id, grp, num, kind, pack, at) values (d.id, u, g, n, 'bara', pk, _now());
        end loop;
      end if;
    end loop;
  end if;
  update lot_draws set sales = sales + cnt, jackpot = jackpot + cnt * 10 where id = d.id;
  perform _log(u, 'lottery', cost, 0, jsonb_build_object('draw', d.id, 'count', cnt, 'kind', p_kind));
  return lot_state();
end $$;

-- 画面：いまの回・自分のくじ・前の回の当せん番号・自分の結果
create or replace function public.lot_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); d lot_draws; l lot_draws;
begin
  begin perform _lot_tick(); exception when others then null; end;
  select * into d from lot_draws where status = 'open' order by id desc limit 1;
  select * into l from lot_draws where status = 'drawn' order by id desc limit 1;
  return jsonb_build_object(
    'draw', case when d.id is null then null else jsonb_build_object('id', d.id, 'at', to_char(d.draw_at at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'),
              'at_ms', floor(extract(epoch from d.draw_at) * 1000)::bigint, 'jackpot', d.jackpot, 'sales', d.sales,
              'mine', (select count(*) from lot_tickets where draw_id = d.id and user_id = u),
              'packs', (select coalesce(jsonb_agg(p order by (p->>'pack')::bigint desc), '[]'::jsonb) from (
                         select jsonb_build_object('pack', pack, 'kind', min(kind), 't', jsonb_agg(jsonb_build_array(grp, num) order by grp, num)) p
                           from lot_tickets where draw_id = d.id and user_id = u group by pack order by pack desc limit 30) z)) end,
    'last', case when l.id is null then null else jsonb_build_object('id', l.id, 'at', to_char(l.draw_at at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'),
              'win', l.win, 'winners', l.winners, 'hit', l.hit, 'jackpot', l.jackpot, 'sales', l.sales,
              'mine', (select count(*) from lot_tickets where draw_id = l.id and user_id = u),
              'mywins', (select coalesce(jsonb_agg(jsonb_build_object('tier', tier, 'g', grp, 'n', num, 'pay', payout) order by case tier when 1 then 0 when 11 then 1 when 12 then 2 else tier + 1 end, grp, num), '[]'::jsonb)
                           from (select * from lot_tickets where draw_id = l.id and user_id = u and tier > 0 order by case tier when 1 then 0 when 11 then 1 when 12 then 2 else tier + 1 end limit 50) w),
              'mypay', (select coalesce(sum(payout), 0)::bigint from lot_tickets where draw_id = l.id and user_id = u),
              'mytiers', (select coalesce(jsonb_object_agg(tier, c), '{}'::jsonb) from (select tier, count(*) c from lot_tickets
                            where draw_id = l.id and user_id = u and tier > 0 group by tier) z)) end,
    'history', (select coalesce(jsonb_agg(h order by (h->>'id')::int desc), '[]'::jsonb) from (
                 select jsonb_build_object('id', t.draw_id, 'count', count(*), 'pay', coalesce(sum(t.payout), 0)) h
                   from lot_tickets t join lot_draws x on x.id = t.draw_id and x.status = 'drawn'
                  where t.user_id = u group by t.draw_id order by t.draw_id desc limit 8) z),
    'prizes', jsonb_build_object('11', _lot_prize(11), '12', _lot_prize(12), '2', _lot_prize(2), '3', _lot_prize(3), '4', _lot_prize(4)),
    'now', floor(extract(epoch from _now()) * 1000)::bigint,
    'balance', _bal(u));
end $$;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-lottery', '* * * * *', 'select public._lot_tick()');
  end if;
end $$;

-- =====================================================================
-- 公営競技：競艇（ボートレース）と競輪
--   競馬のない時間に走る。競艇：9:30〜11:20（朝・12R）と 22:40〜23:50（ミッドナイト・8R）。競輪：13:50〜15:40（12R）
--   選手は架空。成績（競艇は勝率、競輪は競走得点）がつき、毎月（1年＝1か月）級が上がったり下がったりする
--   競艇：6艇・3周1800m。単勝・複勝（2着まで）・2連単・2連複・拡連複・3連単・3連複。フライング（F）の艇をふくむ券は返す
--   競輪：A級7車・S級9車・2025m。同じ地区の選手がライン（3人まで）を組んで走る。2車単・2車複・ワイド・3連単・3連複・2枠単・2枠複（9車のレースだけ）
--   オッズは買った時点で決まる（みんなの見立てから）。払戻率は単勝・複勝80%、ほかは75%
--   券の種類（kind）：tan 単勝・fuku 複勝・ex2 2連単（2車単）・qn2 2連複（2車複）・wide 拡連複（ワイド）・ex3 3連単・tr3 3連複・wex 2枠単・wqn 2枠複
-- =====================================================================
create table if not exists public.pr_venues (
  id       int primary key,
  sport    text not null,                 -- boat 競艇 / bike 競輪
  name     text not null,
  water    text,                          -- 競艇：淡水・海水・汽水
  inbias   numeric not null default 0,    -- 競艇：1コースの強さ（＋なら強い）
  bank     int,                           -- 競輪：周長（m）
  straight numeric                        -- 競輪：みなし直線（m）
);
insert into public.pr_venues(id, sport, name, water, inbias, bank, straight) values
  (1, 'boat', '多摩川', '淡水', 0.12, null, null), (2, 'boat', '平和島', '海水', -0.18, null, null), (3, 'boat', '江戸川', '汽水', -0.08, null, null),
  (11, 'bike', '立川', null, 0, 400, 58.0), (12, 'bike', '京王閣', null, 0, 400, 51.5), (13, 'bike', '平塚', null, 0, 400, 54.2)
on conflict (id) do nothing;
-- 選手
create table if not exists public.pr_racers (
  id       serial primary key,
  sport    text not null check (sport in ('boat', 'bike')),
  regno    int not null,                  -- 登録番号（競艇は4けた。競輪は期×1000＋番号）
  name     text not null,
  name_en  text not null,
  pref     text not null,                 -- 支部（競艇）・府県（競輪）
  area     text not null,                 -- 地区（競輪のラインのもと）
  born     int not null,                  -- 生まれた月（_kb_midx。1年＝1か月）
  term     int,                           -- 競輪：期
  grade    text not null,                 -- 競艇 A1/A2/B1/B2・競輪 S1/S2/A1/A2/A3
  ability  numeric not null,              -- 力（見せない）
  st       numeric,                       -- 競艇：ふだんのスタートタイミング（見せない）
  style    text,                          -- 競輪：逃（先行）・両（自在）・追（追込）
  starts   int not null default 0,
  wins     int not null default 0,
  seconds  int not null default 0,
  thirds   int not null default 0,
  rate     numeric not null,              -- 競艇：勝率・競輪：競走得点（新しいレースほど重く）
  r2       numeric not null,              -- 2連対率（%）
  r3       numeric not null,              -- 3連対率（%）
  st_avg   numeric,                       -- 競艇：平均ST（見せる）
  f_count  int not null default 0,        -- 競艇：フライングの数（毎月0にもどる）
  retired  boolean not null default false,
  last_day date,
  unique (sport, regno)
);
create index if not exists pr_racers_pick_idx on public.pr_racers(sport, retired, grade);
-- 競艇のモーター（場ごとに60機）
create table if not exists public.pr_motors (
  venue  int not null,
  no     int not null,
  power  numeric not null,                -- 力（見せない）
  starts int not null default 0,
  r2     numeric not null,                -- 2連対率（%・見せる）
  primary key (venue, no)
);
-- レース
create table if not exists public.pr_races (
  id        bigint primary key,           -- 日付(YYYYMMDD)*1000 ＋ 100（競艇）/ 200（競輪）＋ その日の番号
  sport     text not null,
  day       date not null,
  no        int not null,                 -- その日の番号（競艇：朝 1〜12・ミッドナイト 13〜20、競輪 1〜12）
  sess      text not null,                -- morning / midnight / day
  post      timestamptz not null,         -- 発走（競艇はスタートの瞬間）
  venue     int not null references public.pr_venues(id),
  rnum      int not null,
  title     text not null,                -- 開催の名前
  name      text not null,                -- レースの名前（一般戦・特選・ドリーム戦…）
  cls       text,                         -- 競輪：S級・A級
  n         int not null,                 -- 艇数・車数
  weather   text not null,
  wind      numeric,                      -- 競艇：風（m）
  wave      int,                          -- 競艇：波（cm）
  finish_ms int,                          -- いちばん最後にゴールした選手の時間
  kimarite  text,                         -- 決まり手（1着の選手）
  plan      jsonb not null default '{}',  -- 絵のため（競艇：1周目1マークのあとの順・競輪：周回とジャンの並び、スピード）
  settled   boolean not null default false
);
create index if not exists pr_races_day_idx on public.pr_races(day, sport, no);
create index if not exists pr_races_open_idx on public.pr_races(settled, post);
-- 出走表
create table if not exists public.pr_entries (
  race_id  bigint not null references public.pr_races(id) on delete cascade,
  num      int not null,                  -- 艇番・車番
  racer_id int not null references public.pr_racers(id),
  waku     int not null,                  -- 枠（競艇は艇番と同じ）
  course   int,                           -- 競艇：進入コース
  motor    int,                           -- 競艇：モーター
  line     int,                           -- 競輪：ライン
  lpos     int,                           -- 競輪：ラインの何番手
  w        numeric not null,              -- みんなの見立て（オッズのもと）
  ninki    int,
  odds_win numeric,                       -- 競艇：単勝オッズ
  st       numeric,                       -- 競艇：スタートタイミング（マイナスはフライング）
  pos      int,                           -- 着順（フライング・落車は null）
  time_ms  int,                           -- ゴールまで
  margin   text,                          -- 競輪：着差
  last     numeric,                       -- 競輪：上がり（最後の200m）
  incident text,                          -- F フライング・fall 落車
  inc_val  numeric,                       -- 落車：最終周回のどこで（0〜1）
  primary key (race_id, num)
);
create index if not exists pr_entries_racer_idx on public.pr_entries(racer_id, race_id desc);
-- 券
create table if not exists public.pr_tickets (
  id         bigserial primary key,
  race_id    bigint not null references public.pr_races(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('tan','fuku','ex2','qn2','wide','ex3','tr3','wex','wqn')),
  sel        int[] not null,
  amount     bigint not null check (amount > 0),
  odds       numeric not null,
  payout     bigint,
  refund     boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists pr_tickets_race_idx on public.pr_tickets(race_id);
create index if not exists pr_tickets_user_idx on public.pr_tickets(user_id, race_id desc);
-- 画面から直接は読めない（着順はレースをつくるときに決まるので、発走の前に見られないように。全部 下の関数を通す）
alter table public.pr_venues  enable row level security;
alter table public.pr_racers  enable row level security;
alter table public.pr_motors  enable row level security;
alter table public.pr_races   enable row level security;
alter table public.pr_entries enable row level security;
alter table public.pr_tickets enable row level security;
revoke all on public.pr_venues, public.pr_racers, public.pr_motors, public.pr_races, public.pr_entries, public.pr_tickets from anon, authenticated;

-- 名前（漢字・ローマ字）。架空の組み合わせ
create or replace function public._pr_name(fem boolean) returns text[]
language plpgsql volatile as $$
declare
  S text[] := array['佐藤:Sato','鈴木:Suzuki','高橋:Takahashi','田中:Tanaka','伊藤:Ito','渡辺:Watanabe','山本:Yamamoto','中村:Nakamura','小林:Kobayashi',
    '加藤:Kato','吉田:Yoshida','山田:Yamada','佐々木:Sasaki','山口:Yamaguchi','松本:Matsumoto','井上:Inoue','木村:Kimura','林:Hayashi','清水:Shimizu',
    '山崎:Yamazaki','森:Mori','池田:Ikeda','橋本:Hashimoto','阿部:Abe','石川:Ishikawa','山下:Yamashita','中島:Nakajima','石井:Ishii','小川:Ogawa',
    '前田:Maeda','岡田:Okada','長谷川:Hasegawa','藤田:Fujita','後藤:Goto','近藤:Kondo','村上:Murakami','遠藤:Endo','青木:Aoki','坂本:Sakamoto',
    '斉藤:Saito','福田:Fukuda','太田:Ota','西村:Nishimura','藤井:Fujii','金子:Kaneko','岡本:Okamoto','藤原:Fujiwara','中野:Nakano','三浦:Miura',
    '原田:Harada','中川:Nakagawa','松田:Matsuda','竹内:Takeuchi','小野:Ono','田村:Tamura','中山:Nakayama','和田:Wada','石田:Ishida','森田:Morita',
    '上田:Ueda','原:Hara','内田:Uchida','柴田:Shibata','酒井:Sakai','宮崎:Miyazaki','横山:Yokoyama','高木:Takagi','安藤:Ando','宮本:Miyamoto',
    '大野:Ono','小島:Kojima','谷口:Taniguchi','今井:Imai','工藤:Kudo','高田:Takada','増田:Masuda','丸山:Maruyama','杉山:Sugiyama','村田:Murata',
    '大塚:Otsuka','新井:Arai','小山:Koyama','平野:Hirano','藤本:Fujimoto','河野:Kono','上野:Ueno','野口:Noguchi','武田:Takeda','松井:Matsui',
    '千葉:Chiba','岩崎:Iwasaki','菅原:Sugawara','木下:Kinoshita','久保:Kubo','佐野:Sano','野村:Nomura','松尾:Matsuo','菊地:Kikuchi','杉本:Sugimoto',
    '市川:Ichikawa','古川:Furukawa','大西:Onishi','島田:Shimada','水野:Mizuno','桜井:Sakurai','高野:Takano','吉川:Yoshikawa','山内:Yamauchi','西田:Nishida',
    '飯田:Iida','北村:Kitamura','安田:Yasuda','五十嵐:Igarashi','川口:Kawaguchi','平田:Hirata','中田:Nakata','服部:Hattori','岩田:Iwata','土屋:Tsuchiya',
    '川崎:Kawasaki','福島:Fukushima','本田:Honda','樋口:Higuchi','秋山:Akiyama','田口:Taguchi','永井:Nagai','山中:Yamanaka','中西:Nakanishi','吉村:Yoshimura',
    '川上:Kawakami','石原:Ishihara','大橋:Ohashi','松岡:Matsuoka','馬場:Baba','浅野:Asano','荒木:Araki','野田:Noda','小池:Koike','田辺:Tanabe',
    '松下:Matsushita','菅野:Kanno','熊谷:Kumagai','大石:Oishi'];
  M text[] := array['翔太:Shota','大輔:Daisuke','拓也:Takuya','健太:Kenta','直樹:Naoki','和也:Kazuya','達也:Tatsuya','浩二:Koji','誠:Makoto','剛:Tsuyoshi',
    '亮:Ryo','隆:Takashi','学:Manabu','修:Osamu','聡:Satoshi','武:Takeshi','勇気:Yuki','翼:Tsubasa','蓮:Ren','悠斗:Yuto','陸:Riku','颯太:Sota',
    '大和:Yamato','海斗:Kaito','拓海:Takumi','翔:Sho','優太:Yuta','雄大:Yudai','智也:Tomoya','竜也:Tatsuya','秀樹:Hideki','正人:Masato','光太郎:Kotaro',
    '慎吾:Shingo','健一:Kenichi','康平:Kohei','伸也:Shinya','圭介:Keisuke','将太:Shota','隼人:Hayato','大地:Daichi','祐介:Yusuke','雅人:Masato',
    '健二:Kenji','一輝:Kazuki','啓太:Keita','純:Jun','敦:Atsushi','幸一:Koichi','博之:Hiroyuki','晃:Akira','豊:Yutaka','弘:Hiroshi','稔:Minoru',
    '茂:Shigeru','進:Susumu','卓也:Takuya','洋平:Yohei','憲一:Kenichi','哲也:Tetsuya','克也:Katsuya','信也:Shinya','俊介:Shunsuke','匠:Takumi',
    '航:Wataru','陽介:Yosuke','昌平:Shohei','太一:Taichi','涼:Ryo','大樹:Daiki','恭平:Kyohei','和樹:Kazuki','尚人:Naoto','秀人:Hideto',
    '勝也:Katsuya','功:Isao','宏:Hiroshi','剛志:Tsuyoshi','裕太:Yuta','雄一:Yuichi'];
  F text[] := array['美咲:Misaki','彩:Aya','愛:Ai','舞:Mai','優花:Yuka','千尋:Chihiro','真由:Mayu','遥:Haruka','結衣:Yui','沙織:Saori','恵:Megumi',
    '香織:Kaori','菜々:Nana','茜:Akane','楓:Kaede','葵:Aoi','杏奈:Anna','梨花:Rika','由佳:Yuka','麻衣:Mai','理沙:Risa','瞳:Hitomi','七海:Nanami',
    '美穂:Miho','加奈:Kana'];
  a text[]; b text[];
begin
  a := string_to_array(S[1 + floor(random() * cardinality(S))::int], ':');
  if fem then b := string_to_array(F[1 + floor(random() * cardinality(F))::int], ':');
  else b := string_to_array(M[1 + floor(random() * cardinality(M))::int], ':'); end if;
  return array[a[1] || ' ' || b[1], b[2] || ' ' || a[2]];
end $$;

-- 選手をつくる（gr：級、age：年齢）
create or replace function public._pr_new_racer(sp text, gr text, age int) returns int
language plpgsql volatile set search_path = public as $$
declare
  a numeric; nm text[]; fem boolean := sp = 'boat' and random() < 0.12; pf text; ar text; st0 numeric; sty text; reg int; tm int;
  rate0 numeric; r20 numeric; rid int; i int; x text[]; cur int := _kb_midx(_now());
  BP text[] := array['東京','埼玉','群馬','静岡','愛知','三重','福井','滋賀','大阪','兵庫','徳島','香川','岡山','広島','山口','福岡','佐賀','長崎'];
  KP text[] := array['北海道:北日本','青森:北日本','岩手:北日本','宮城:北日本','福島:北日本','茨城:関東','栃木:関東','群馬:関東','埼玉:関東','新潟:関東',
    '長野:関東','千葉:南関東','東京:南関東','神奈川:南関東','静岡:南関東','山梨:南関東','愛知:中部','岐阜:中部','三重:中部','富山:中部','石川:中部',
    '大阪:近畿','京都:近畿','兵庫:近畿','奈良:近畿','和歌山:近畿','滋賀:近畿','福井:近畿','岡山:中国','広島:中国','山口:中国','鳥取:中国',
    '香川:四国','徳島:四国','愛媛:四国','高知:四国','福岡:九州','佐賀:九州','長崎:九州','熊本:九州','大分:九州','宮崎:九州','鹿児島:九州'];
begin
  a := (case gr when 'S1' then 1.0 when 'S2' then 0.4 when 'A3' then -1.0 when 'B1' then -0.25 when 'B2' then -0.9
               when 'A1' then case when sp = 'boat' then 1.1 else -0.1 end
               when 'A2' then case when sp = 'boat' then 0.45 else -0.5 end else 0 end) + _kb_norm() * 0.3;
  for i in 1..40 loop
    nm := _pr_name(fem);
    exit when not exists (select 1 from pr_racers where sport = sp and name = nm[1]);
  end loop;
  if sp = 'boat' then
    pf := BP[1 + floor(random() * cardinality(BP))::int]; ar := pf;
    st0 := round(least(0.23, greatest(0.10, 0.17 - 0.025 * a + _kb_norm() * 0.012)), 3);
    reg := 5350 - (age - 20) * 40 + floor(random() * 40)::int;
    rate0 := round(least(8.6, greatest(2.0, 5.3 + 1.6 * a + _kb_norm() * 0.35)), 2);
    r20 := round(least(75, greatest(5, 33 + 16 * a + _kb_norm() * 4)), 1);
  else
    x := string_to_array(KP[1 + floor(random() * cardinality(KP))::int], ':'); pf := x[1]; ar := x[2];
    sty := case when random() < 0.35 then '逃' when random() < 0.4 then '両' else '追' end;
    tm := 127 - (age - 20) + floor(random() * 2)::int;
    reg := tm * 1000 + floor(random() * 900)::int;
    rate0 := round(96 + 13 * a + _kb_norm() * 1.5, 2);
    r20 := round(least(70, greatest(3, 25 + 14 * (a - case when gr like 'S%' then 0.6 else -0.5 end) + _kb_norm() * 4)), 1);
  end if;
  while exists (select 1 from pr_racers where sport = sp and regno = reg) loop reg := reg + 1; end loop;
  insert into pr_racers(sport, regno, name, name_en, pref, area, born, term, grade, ability, st, style, rate, r2, r3, st_avg)
  values (sp, reg, nm[1], nm[2], pf, ar, cur - age, tm, gr, round(a, 3), st0, sty, rate0, r20,
          round(least(92, r20 + 15 + _kb_norm() * 3), 1), case when sp = 'boat' then round(st0 + _kb_norm() * 0.008, 2) end)
  returning id into rid;
  return rid;
end $$;

-- 天気
create or replace function public._pr_wx() returns text
language sql volatile as $$ select case when random() < 0.55 then '晴' when random() < 0.67 then '曇' else '雨' end $$;

-- 競輪：ラインの中の位置による強さ（lead：そのラインが先行するか）
create or replace function public._pr_bonus(lpos int, lsize int, sty text, lead boolean) returns numeric
language sql immutable as $$
  select (case when lead then (array[0.35, 0.75, 0.25])[least(lpos, 3)]
               when lsize = 1 then -0.15
               when lpos = 1 then case when sty in ('逃', '両') then 0.15 else -0.1 end
               when lpos = 2 then 0.2 else -0.05 end)::numeric $$;

-- 競輪：着差（m → ことば）
create or replace function public._pr_margin(m numeric) returns text
language sql immutable as $$
  select case when m < 0.1 then 'タイヤ差' when m < 0.2 then '1/8輪' when m < 0.35 then '1/4輪' when m < 0.55 then '1/2輪'
              when m < 0.75 then '3/4輪' when m < 0.95 then '1輪' when m < 1.3 then '1/2車身' when m < 1.6 then '3/4車身'
              when m < 2.6 then '1車身' when m < 4.4 then '2車身' when m < 6.2 then '3車身' when m < 8 then '4車身' else '大差' end $$;

-- 1レースをつくる（出る選手・着順・タイムまで、ここで決まる。見せるのは発走のあと）
--   top：上位の選手をえらぶ（特選・ドリーム戦・決勝など）。gs：えらぶ級（競輪）
create or replace function public._pr_make_race(sp text, d date, no int, sess text, vid int, rnum int, post timestamptz,
                                               ttl text, rname text, cls text, n int, top boolean, gs text[], wx text) returns bigint
language plpgsql volatile set search_path = public as $$
declare
  rid bigint := to_char(d, 'YYYYMMDD')::bigint * 1000 + (case when sp = 'boat' then 100 else 200 end) + no;
  v pr_venues; ids int[]; i int; j int; k int; rr pr_racers; mot int[]; mp numeric; mr numeric; rec record;
  A numeric[] := '{}'; AE numeric[] := '{}'; ST numeric[] := '{}'; sc numeric[] := '{}'; pub numeric[] := '{}'; fl boolean[] := '{}';
  cb numeric[] := array[1.75, 0.6, 0.5, 0.3, 0.0, -0.35]; ord int[]; m1 int[]; kim text; plan jsonb;
  wind numeric; wave int; beta numeric := 1; t1 numeric; tm numeric[]; x numeric; y numeric;
  ar text[] := '{}'; sty text[] := '{}'; ln int[]; lp int[]; nl int := 0; lead int; pw numeric[]; pe numeric[]; tot numeric; tote numeric;
  fall int; lo int[]; laps int[]; bell int[]; v1 numeric; v2 numeric; v3 numeric; mg text[]; lst numeric[]; wk int[]; sz int; fv numeric;
  pat text; ar1 text; usd text[] := '{}';
begin
  if exists (select 1 from pr_races where id = rid) then return rid; end if;
  select * into v from pr_venues where id = vid;
  -- 選手をえらぶ：競艇は1日2回まで・競輪は1日1回まで。ひとつ前のレースに出た選手はのぞく
  ids := '{}';
  if sp = 'bike' and not top then
    -- 競輪：ラインができるように、地区を3〜5つえらんで、それぞれから選手をえらぶ（3-3-3・3-3-2-1・3-2-2 など）
    pat := case when n = 9 then (array['3,3,3', '3,3,2,1', '3,2,2,2', '3,3,2,1', '2,2,2,2,1'])[1 + floor(random() * 5)::int]
                else (array['3,2,2', '3,3,1', '2,2,2,1', '3,2,2'])[1 + floor(random() * 4)::int] end;
    foreach sz in array string_to_array(pat, ',')::int[] loop
      ar1 := null;
      select q.area into ar1 from (
        select r.area, count(*) c from pr_racers r
         where r.sport = 'bike' and not r.retired and r.grade = any(gs) and not (r.id = any(ids))
           and not exists (select 1 from pr_entries e join pr_races q2 on q2.id = e.race_id where e.racer_id = r.id and q2.day = d and q2.sport = 'bike')
         group by r.area) q
       where q.c >= sz and not (q.area = any(usd)) order by random() limit 1;
      continue when ar1 is null;
      usd := usd || ar1;
      ids := ids || array(select r.id from pr_racers r
                           where r.sport = 'bike' and not r.retired and r.grade = any(gs) and r.area = ar1 and not (r.id = any(ids))
                             and not exists (select 1 from pr_entries e join pr_races q2 on q2.id = e.race_id where e.racer_id = r.id and q2.day = d and q2.sport = 'bike')
                           order by random() limit sz);
    end loop;
  end if;
  if cardinality(ids) < n then
    select ids || coalesce(array_agg(z.id), '{}') into ids from (
      select r.id from pr_racers r
       where r.sport = sp and not r.retired and (gs is null or r.grade = any(gs)) and not (r.id = any(ids))
         and (select count(*) from pr_entries e join pr_races q on q.id = e.race_id where e.racer_id = r.id and q.day = d and q.sport = sp)
             < (case when sp = 'boat' then 2 else 1 end)
         and not exists (select 1 from pr_entries e where e.race_id = rid - 1 and e.racer_id = r.id)
       order by case when top then -(r.rate * (case when sp = 'boat' then 1 else 0.1 end) + random() * 0.8) else random() end
       limit n - cardinality(ids)) z;
  end if;
  if cardinality(ids) < n then   -- まだ足りなければ、ほかの選手も（その日にまだ走っていない選手から）
    select ids || coalesce(array_agg(z.id), '{}') into ids from (
      select r.id from pr_racers r where r.sport = sp and not r.retired and not (r.id = any(ids))
       order by exists (select 1 from pr_entries e join pr_races q on q.id = e.race_id where e.racer_id = r.id and q.day = d and q.sport = sp),
                (gs is not null and r.grade = any(gs)) desc, random() limit n - cardinality(ids)) z;
  end if;
  -- 番号：力のありそうな選手ほど内（1号艇・1番車）に来やすい
  select array_agg(z.id order by z.k desc) into ids from (
    select r.id, r.rate * (case when sp = 'boat' then 1 else 0.1 end) + random() * (case when top then 0.4 else 2.2 end) k
      from pr_racers r where r.id = any(ids)) z;

  if sp = 'boat' then
    wind := round((random() * 6)::numeric, 0); wave := (wind * 1.2 + random() * 3)::int;
    beta := 1 + wave / 40.0;
    mot := array(select mm.no from pr_motors mm where mm.venue = vid order by random() limit 6);
    for i in 1..n loop
      select * into rr from pr_racers where id = ids[i];
      select mm.power, mm.r2 into mp, mr from pr_motors mm where mm.venue = vid and mm.no = mot[i];
      ST := ST || round(greatest(-0.08, rr.st + _kb_norm() * 0.05), 2);
      fl := fl || (ST[i] < 0);
      x := cb[i] + case when i = 1 then v.inbias else 0 end;
      sc := sc || (x + 0.9 * rr.ability + 0.45 * coalesce(mp, 0) - 7 * (ST[i] - 0.15) + beta * _kb_gumbel());
      pub := pub || (x + 0.9 * (rr.rate - 5.3) / 1.6 + 0.45 * (coalesce(mr, 33) - 33) / 11.0 - 3 * (coalesce(rr.st_avg, 0.16) - 0.15));
    end loop;
    ord := array(select g from generate_series(1, n) g where not fl[g] order by sc[g] desc);
    -- 1周目1マークのあとの順（ときどき、あとで抜く）
    m1 := ord;
    if cardinality(m1) >= 2 and random() < 0.07 then m1 := array[m1[2], m1[1]] || m1[3:]; end if;
    if cardinality(m1) >= 4 and random() < 0.3 then m1 := m1[1:2] || array[m1[4], m1[3]] || m1[5:]; end if;
    kim := case when cardinality(ord) = 0 then null
                when m1[1] <> ord[1] then '抜き'
                when fl[1] and ord[1] <> 1 then '恵まれ'
                when ord[1] = 1 then '逃げ'
                when ord[1] = 2 then case when random() < 0.75 then '差し' else 'まくり' end
                else case when random() < 0.5 then 'まくり' else 'まくり差し' end end;
    t1 := 106.5 + random() * 3 + wave * 0.1;
    tm := array_fill(null::numeric, array[n]);
    x := t1;
    for k in 1..cardinality(ord) loop
      if k > 1 then x := x + 0.35 + random() * 2.0 + (k - 2) * random() * 0.8; end if;
      tm[ord[k]] := x;
    end loop;
    plan := jsonb_build_object('m1', to_jsonb(m1));
    insert into pr_races(id, sport, day, no, sess, post, venue, rnum, title, name, cls, n, weather, wind, wave, finish_ms, kimarite, plan)
    values (rid, sp, d, no, sess, post, vid, rnum, ttl, rname, cls, n, wx, wind, wave, round(x * 1000)::int, kim, plan);
    for i in 1..n loop
      insert into pr_entries(race_id, num, racer_id, waku, course, motor, w, st, pos, time_ms, incident)
      values (rid, i, ids[i], i, i, mot[i], round(exp(pub[i] * 0.8), 6), ST[i], array_position(ord, i), round(tm[i] * 1000)::int, case when fl[i] then 'F' end);
    end loop;
  else
    for i in 1..n loop
      select * into rr from pr_racers where id = ids[i];
      A := A || rr.ability; AE := AE || ((rr.rate - 96) / 13.0);
      ar := ar || rr.area; sty := sty || coalesce(rr.style, '追');
    end loop;
    -- ライン：同じ地区の選手が組む（3人まで）。前から 逃 → 両 → 追、それぞれ力の強い順
    ln := array_fill(0, array[n]); lp := array_fill(0, array[n]);
    for rec in select q.a2 from (select distinct unnest(ar) a2) q order by random() loop
      j := 0;
      for i in select g from generate_series(1, n) g where ar[g] = rec.a2
                order by case sty[g] when '逃' then 0 when '両' then 1 else 2 end, A[g] desc loop
        if j % 3 = 0 then nl := nl + 1; end if;
        j := j + 1;
        ln[i] := nl; lp[i] := (j - 1) % 3 + 1;
      end loop;
    end loop;
    -- 先頭の選手の力で、どのラインが先行（主導権）をとるか
    pw := array_fill(0::numeric, array[nl]); pe := array_fill(0::numeric, array[nl]);
    for i in 1..n loop
      if lp[i] = 1 then
        x := case sty[i] when '逃' then 0.3 when '両' then 0.1 else -0.4 end;
        pw[ln[i]] := A[i] + x; pe[ln[i]] := AE[i] + x;
      end if;
    end loop;
    tot := 0; tote := 0;
    for k in 1..nl loop tot := tot + exp(2.2 * pw[k]); tote := tote + exp(2.2 * pe[k]); end loop;
    x := random() * tot; lead := nl;
    for k in 1..nl loop x := x - exp(2.2 * pw[k]); if x <= 0 then lead := k; exit; end if; end loop;
    for i in 1..n loop
      sz := (select count(*) from generate_series(1, n) g where ln[g] = ln[i]);
      y := exp(2.2 * pe[ln[i]]) / tote;
      sc := sc || (2.3 * A[i] + _pr_bonus(lp[i], sz, sty[i], ln[i] = lead) + _kb_gumbel());
      pub := pub || (2.3 * AE[i] + y * _pr_bonus(lp[i], sz, sty[i], true) + (1 - y) * _pr_bonus(lp[i], sz, sty[i], false));
    end loop;
    ord := array(select g from generate_series(1, n) g order by sc[g] desc);
    if random() < 0.015 then   -- 落車（たまに）
      fall := ord[2 + floor(random() * (n - 1))::int];
      ord := array_remove(ord, fall);
    end if;
    kim := case when ln[ord[1]] = lead then case when lp[ord[1]] = 1 then '逃げ' else '差し' end
                when lp[ord[1]] = 1 then '捲り' else '差し' end;
    -- 周回の並び（ラインごと。先行するラインはうしろから行くことが多い）と、ジャン（打鐘）のあとの並び
    lo := array(select gk from generate_series(1, nl) gk order by random() + case when gk = lead then 0.5 else 0 end);
    laps := array(select g from unnest(lo) with ordinality u(k, o) join generate_series(1, n) g on ln[g] = u.k order by u.o, lp[g]);
    bell := array(select g from unnest(lo) with ordinality u(k, o) join generate_series(1, n) g on ln[g] = u.k order by (u.k = lead) desc, u.o, lp[g]);
    -- スピード（周回 → 残り2周 → 最終周回）とタイム・着差・上がり
    v1 := round((14.2 + random() * 0.4)::numeric, 2); v2 := round((15.6 + random() * 0.4)::numeric, 2); v3 := round((17.4 + random() * 0.5)::numeric, 2);
    t1 := 1225 / v1 + 400 / v2 + 400 / v3;
    tm := array_fill(null::numeric, array[n]); mg := array_fill(null::text, array[n]); lst := array_fill(null::numeric, array[n]);
    x := 0;
    for k in 1..cardinality(ord) loop
      y := case when k = 1 then 0 when k = 2 then 0.1 + random() * 2.0 when k = 3 then 0.15 + random() * 2.2 else 0.4 + random() * 2.8 end;
      x := x + y;
      tm[ord[k]] := t1 + x / v3;
      if k > 1 then mg[ord[k]] := _pr_margin(y); end if;
      lst[ord[k]] := round((11.0 + random() * 0.6 + (k - 1) * 0.05)::numeric, 1);
    end loop;
    fv := case when fall is not null then round((0.3 + random() * 0.6)::numeric, 3) end;
    wk := case when n = 9 then array[1, 2, 3, 4, 4, 5, 5, 6, 6] else array[1, 2, 3, 4, 5, 6, 6] end;
    plan := jsonb_build_object('laps', to_jsonb(laps), 'bell', to_jsonb(bell), 'lead', lead,
              'lines', (select jsonb_agg(z.m order by z.o) from (select u.o, jsonb_agg(g order by lp[g]) m
                          from unnest(lo) with ordinality u(k, o) join generate_series(1, n) g on ln[g] = u.k group by u.o) z),
              'v', jsonb_build_array(v1, v2, v3));
    insert into pr_races(id, sport, day, no, sess, post, venue, rnum, title, name, cls, n, weather, finish_ms, kimarite, plan)
    values (rid, sp, d, no, sess, post, vid, rnum, ttl, rname, cls, n, wx, round(t1 * 1000 + x / v3 * 1000)::int, kim, plan);
    for i in 1..n loop
      insert into pr_entries(race_id, num, racer_id, waku, line, lpos, w, pos, time_ms, margin, last, incident, inc_val)
      values (rid, i, ids[i], wk[i], ln[i], lp[i], round(exp(pub[i] * 1.3), 6), array_position(ord, i), round(tm[i] * 1000)::int, mg[i], lst[i],
              case when i = fall then 'fall' end, case when i = fall then fv end);
    end loop;
  end if;
  update pr_entries e set ninki = z.rk from (select num, row_number() over (order by w desc, num) rk from pr_entries where race_id = rid) z
   where e.race_id = rid and e.num = z.num;
  if sp = 'boat' then update pr_entries set odds_win = _pr_odds(rid, 'tan', array[num]) where race_id = rid; end if;
  return rid;
end $$;

-- 1日の番組をつくる（競艇：朝12R・ミッドナイト8R、競輪：12R）
create or replace function public._pr_make_day(sp text, d date) returns void
language plpgsql volatile set search_path = public as $$
declare
  dn int := d - date '2026-01-01'; sun boolean := extract(isodow from d) = 7; wx text; i int; base timestamptz; vid int; ttl text; nm text;
  gs text[]; n int; cl text;
  cups text[] := array['風の芽杯', '帝都京浜新聞社杯', '大東亰記念', '若葉賞', 'AiliNaX杯', '神楽坂通商事杯', '秋桜カップ'];
  y int := extract(year from d)::int; mo int := extract(month from d)::int; dd int := extract(day from d)::int;
begin
  perform pg_advisory_xact_lock(7802);
  if exists (select 1 from pr_races where day = d and sport = sp) then return; end if;
  if sp = 'boat' then
    vid := (array[1, 3, 2])[1 + dn % 3]; wx := _pr_wx();
    ttl := (select name from pr_venues where id = vid) || ' ' || cups[1 + dn % 7];
    base := make_timestamptz(y, mo, dd, 9, 30, 0, 'Asia/Tokyo');
    for i in 1..12 loop
      nm := case when i = 12 then case when sun then '優勝戦' else 'ドリーム戦' end when i >= 10 then '特選' else '一般戦' end;
      perform _pr_make_race('boat', d, i, 'morning', vid, i, base + make_interval(mins => (i - 1) * 10), ttl, nm, null, 6, i >= 10, null, wx);
    end loop;
    vid := (array[2, 1, 3])[1 + dn % 3]; wx := _pr_wx();
    ttl := (select name from pr_venues where id = vid) || ' ミッドナイト ' || cups[1 + (dn + 3) % 7];
    base := make_timestamptz(y, mo, dd, 22, 40, 0, 'Asia/Tokyo');
    for i in 1..8 loop
      nm := case when i = 8 then '選抜戦' when i = 7 then '特選' else '一般戦' end;
      perform _pr_make_race('boat', d, 12 + i, 'midnight', vid, i, base + make_interval(mins => (i - 1) * 10), ttl, nm, null, 6, i >= 7, null, wx);
    end loop;
  else
    vid := (array[11, 12, 13])[1 + dn % 3]; wx := _pr_wx();
    ttl := (select name from pr_venues where id = vid) || ' ' || cups[1 + (dn + 5) % 7];
    base := make_timestamptz(y, mo, dd, 13, 50, 0, 'Asia/Tokyo');
    for i in 1..12 loop
      if i <= 3 then nm := 'A級チャレンジ'; cl := 'A'; gs := array['A3']; n := 7;
      elsif i <= 6 then nm := 'A級一般'; cl := 'A'; gs := array['A1', 'A2']; n := 7;
      elsif i <= 10 then nm := 'S級一般'; cl := 'S'; gs := array['S1', 'S2']; n := 9;
      elsif i = 11 then nm := 'S級特選'; cl := 'S'; gs := array['S1', 'S2']; n := 9;
      else nm := case when sun then 'S級決勝' else 'S級選抜' end; cl := 'S'; gs := array['S1', 'S2']; n := 9;
      end if;
      perform _pr_make_race('bike', d, i, 'day', vid, i, base + make_interval(mins => (i - 1) * 10), ttl, nm, cl, n, i >= 11, gs, wx);
    end loop;
  end if;
end $$;

-- 当たる確率（みんなの見立て。順番つきの確率は競馬と同じ式）
create or replace function public._pr_prob(rid bigint, kind text, sel int[]) returns numeric
language plpgsql stable set search_path = public as $$
declare w numeric[]; wk int[]; n int; tw numeric := 0; p numeric := 0; i int; j int; x int; a int := sel[1]; b int := sel[2]; c int := sel[3];
begin
  select array_agg(e.w order by e.num), array_agg(e.waku order by e.num) into w, wk from pr_entries e where e.race_id = rid;
  n := cardinality(w);
  for i in 1..n loop tw := tw + w[i]; end loop;
  case kind
    when 'tan' then p := w[a] / tw;
    when 'fuku' then   -- 2着まで
      p := w[a] / tw;
      for x in 1..n loop continue when x = a; p := p + _kb_seq(w, tw, array[x, a]); end loop;
    when 'ex2' then p := _kb_seq(w, tw, array[a, b]);
    when 'qn2' then p := _kb_seq(w, tw, array[a, b]) + _kb_seq(w, tw, array[b, a]);
    when 'ex3' then p := _kb_seq(w, tw, array[a, b, c]);
    when 'tr3' then p := _kb_prob_trio(w, tw, a, b, c);
    when 'wide' then
      for x in 1..n loop continue when x = a or x = b; p := p + _kb_prob_trio(w, tw, a, b, x); end loop;
    when 'wex', 'wqn' then
      for i in 1..n loop
        for j in 1..n loop
          continue when i = j;
          if (wk[i] = a and wk[j] = b) or (kind = 'wqn' and a <> b and wk[i] = b and wk[j] = a) then p := p + _kb_seq(w, tw, array[i, j]); end if;
        end loop;
      end loop;
    else p := 0;
  end case;
  return p;
end $$;

create or replace function public._pr_rate(kind text) returns numeric
language sql immutable as $$ select (case when kind in ('tan', 'fuku') then 0.80 else 0.75 end)::numeric $$;

-- オッズ（0.1倍きざみで切り捨て。最低1.0倍）。50倍をこえる大穴は少しおさえる（ほんとうの売り場と同じように、大穴は買われすぎる）
create or replace function public._pr_odds(rid bigint, kind text, sel int[]) returns numeric
language plpgsql stable set search_path = public as $$
declare p numeric := _pr_prob(rid, kind, sel); o numeric;
begin
  if p <= 0 then return 99999.9; end if;
  o := _pr_rate(kind) / p;
  if o > 50 then o := 50 * power(o / 50, 0.88); end if;
  return round(least(99999.9, greatest(1.0, floor(o * 10) / 10)), 1);
end $$;

-- 券の選び方を確かめて、決まった形にそろえる
create or replace function public._pr_check_sel(rid bigint, kind text, sel int[]) returns int[]
language plpgsql stable set search_path = public as $$
declare r pr_races; need int; x int; wk int[];
begin
  select * into r from pr_races where id = rid;
  if not found then raise exception 'レースが見つかりません'; end if;
  if r.sport = 'boat' and coalesce(kind, '') not in ('tan', 'fuku', 'ex2', 'qn2', 'wide', 'ex3', 'tr3') then raise exception 'その券は競艇では買えません'; end if;
  if r.sport = 'bike' and coalesce(kind, '') not in ('ex2', 'qn2', 'wide', 'ex3', 'tr3', 'wex', 'wqn') then raise exception 'その券は競輪では買えません'; end if;
  if kind in ('wex', 'wqn') and r.n < 9 then raise exception '2枠単・2枠複は、9車のレースだけです'; end if;
  need := case kind when 'tan' then 1 when 'fuku' then 1 when 'ex3' then 3 when 'tr3' then 3 else 2 end;
  if sel is null or coalesce(cardinality(sel), 0) <> need then raise exception '%つえらんでください', need; end if;
  if kind in ('wex', 'wqn') then
    select array_agg(waku order by num) into wk from pr_entries where race_id = rid;
    foreach x in array sel loop
      if x is null or x < 1 or x > 6 then raise exception '枠は1〜6です'; end if;
    end loop;
    if sel[1] = sel[2] and (select count(*) from unnest(wk) z where z = sel[1]) < 2 then raise exception 'この枠には1人しかいません'; end if;
    if kind = 'wqn' then return array[least(sel[1], sel[2]), greatest(sel[1], sel[2])]; end if;
    return sel;
  end if;
  foreach x in array sel loop
    if x is null or x < 1 or x > r.n then raise exception '番号は1〜%です', r.n; end if;
  end loop;
  if (select count(distinct z) from unnest(sel) z) <> need then raise exception '同じ番号は2回えらべません'; end if;
  if kind in ('qn2', 'wide', 'tr3') then return array(select z from unnest(sel) z order by z); end if;
  return sel;
end $$;

-- 当たったか（res：着順、wk：枠）
create or replace function public._pr_hit(kind text, sel int[], res int[], wk int[]) returns boolean
language sql immutable as $$
  select coalesce(case kind
    when 'tan'  then sel[1] = res[1]
    when 'fuku' then sel[1] = any(res[1:2])
    when 'ex2'  then sel[1] = res[1] and sel[2] = res[2]
    when 'qn2'  then least(res[1], res[2]) = sel[1] and greatest(res[1], res[2]) = sel[2]
    when 'wide' then sel[1] = any(res[1:3]) and sel[2] = any(res[1:3]) and cardinality(res) >= 3
    when 'ex3'  then sel = res[1:3]
    when 'tr3'  then cardinality(res) >= 3 and sel @> res[1:3] and res[1:3] @> sel
    when 'wex'  then wk[res[1]] = sel[1] and wk[res[2]] = sel[2]
    when 'wqn'  then least(wk[res[1]], wk[res[2]]) = sel[1] and greatest(wk[res[1]], wk[res[2]]) = sel[2]
    else false end, false) $$;

-- 発売の状態
create or replace function public._pr_status(r public.pr_races) returns text
language sql stable as $$
  select case when r.settled then 'final'
              when public._now() < r.post - interval '60 seconds' then 'sale'
              when public._now() < r.post then 'closed'
              when public._now() < r.post + make_interval(secs => (coalesce(r.finish_ms, 0) + 1500) / 1000.0) then 'running'
              else 'judging' end $$;

-- 確定して払い戻す。選手とモーターの成績も
create or replace function public._pr_settle(rid bigint) returns void
language plpgsql volatile set search_path = public as $$
declare r pr_races; t pr_tickets; e pr_entries; res int[]; wk int[]; fl int[]; hit boolean; pay bigint; rf boolean; pts numeric; g text;
begin
  select * into r from pr_races where id = rid for update;
  if not found or r.settled then return; end if;
  select coalesce(array_agg(num order by pos), '{}') into res from pr_entries where race_id = rid and pos is not null;
  select coalesce(array_agg(num), '{}') into fl from pr_entries where race_id = rid and incident = 'F';
  select array_agg(waku order by num) into wk from pr_entries where race_id = rid;
  g := case when r.sport = 'boat' then 'boat' else 'keirin' end;
  for t in select * from pr_tickets where race_id = rid and payout is null order by id for update loop
    rf := t.kind not in ('wex', 'wqn') and t.sel && fl;      -- フライングの艇をふくむ券は返す
    hit := not rf and _pr_hit(t.kind, t.sel, res, wk);
    pay := case when rf then t.amount when hit then floor(t.amount * t.odds) else 0 end;
    update pr_tickets set payout = pay, refund = rf where id = t.id;
    perform _give(t.user_id, pay);
    perform _log(t.user_id, g, t.amount, pay, jsonb_build_object('pr', rid, 'kind', t.kind, 'sel', t.sel) || case when rf then '{"refund": true}'::jsonb else '{}'::jsonb end);
  end loop;
  for e in select * from pr_entries where race_id = rid loop
    if r.sport = 'boat' then
      pts := case when e.incident = 'F' then 0 else coalesce((array[10, 8, 6, 4, 2, 1])[e.pos], 0) end;
      update pr_racers set starts = starts + 1, wins = wins + coalesce((e.pos = 1)::int, 0), seconds = seconds + coalesce((e.pos = 2)::int, 0),
             thirds = thirds + coalesce((e.pos = 3)::int, 0), rate = round(rate * 0.94 + pts * 0.06, 3),
             r2 = round(r2 * 0.94 + case when e.pos <= 2 then 6 else 0 end, 2), r3 = round(r3 * 0.94 + case when e.pos <= 3 then 6 else 0 end, 2),
             st_avg = case when e.incident = 'F' or e.st is null then st_avg else round(coalesce(st_avg, e.st) * 0.9 + e.st * 0.1, 3) end,
             f_count = f_count + case when e.incident = 'F' then 1 else 0 end, last_day = r.day
       where id = e.racer_id;
      update pr_motors set starts = starts + 1, r2 = round(r2 * 0.95 + case when e.pos <= 2 then 5 else 0 end, 2) where venue = r.venue and no = e.motor;
    else
      pts := (case when r.cls = 'S' then 100 else 80 end) + coalesce((array[20, 16, 13, 10, 8, 6, 4, 2, 0])[e.pos], 0);
      update pr_racers set starts = starts + 1, wins = wins + coalesce((e.pos = 1)::int, 0), seconds = seconds + coalesce((e.pos = 2)::int, 0),
             thirds = thirds + coalesce((e.pos = 3)::int, 0), rate = round(rate * 0.9 + pts * 0.1, 3),
             r2 = round(r2 * 0.9 + case when e.pos <= 2 then 10 else 0 end, 2), r3 = round(r3 * 0.9 + case when e.pos <= 3 then 10 else 0 end, 2),
             last_day = r.day
       where id = e.racer_id;
    end if;
  end loop;
  update pr_races set settled = true where id = rid;
end $$;

-- 月が変わったら（1年＝1か月）：力の変化・引退・級の見なおし（競輪はS級とA級の入れかえも）・新人
create or replace function public._pr_month(cur int) returns void
language plpgsql volatile set search_path = public as $$
declare i int; n int;
begin
  update pr_racers set ability = round(ability + case when cur - born < 30 then 0.04 when cur - born > 45 then -0.04 else 0 end + _kb_norm() * 0.05, 3)
   where not retired;
  update pr_racers set retired = true
   where not retired and ((sport = 'boat' and (cur - born >= 62 or (grade = 'B2' and cur - born >= 45 and random() < 0.3)))
                       or (sport = 'bike' and (cur - born >= 58 or (grade = 'A3' and cur - born >= 42 and random() < 0.3))));
  -- 新人（引退したぶん）
  n := 180 - (select count(*) from pr_racers where sport = 'boat' and not retired);
  for i in 1..greatest(n, 0) loop perform _pr_new_racer('boat', 'B2', 20 + floor(random() * 5)::int); end loop;
  n := 200 - (select count(*) from pr_racers where sport = 'bike' and not retired);
  for i in 1..greatest(n, 0) loop perform _pr_new_racer('bike', 'A3', 20 + floor(random() * 5)::int); end loop;
  with dn as (select id from pr_racers where sport = 'bike' and not retired and grade like 'S%' order by rate limit 5),
       up as (select id from pr_racers where sport = 'bike' and not retired and grade like 'A%' order by rate desc limit 5)
  update pr_racers p set grade = case when p.id in (select id from dn) then 'A1' else 'S2' end,
                         rate = p.rate + case when p.id in (select id from dn) then -14 else 14 end
   where p.id in (select id from dn union all select id from up);
  with s as (select id, sport, grade, row_number() over (partition by sport, (grade like 'S%') order by rate desc) rk,
                    count(*) over (partition by sport, (grade like 'S%')) cnt
               from pr_racers where not retired)
  update pr_racers p set f_count = 0, grade = case
      when s.sport = 'boat' then case when s.rk <= s.cnt * 0.2 then 'A1' when s.rk <= s.cnt * 0.4 then 'A2' when s.rk <= s.cnt * 0.9 then 'B1' else 'B2' end
      when s.grade like 'S%' then case when s.rk <= s.cnt * 0.375 then 'S1' else 'S2' end
      else case when s.rk <= s.cnt * 0.42 then 'A1' when s.rk <= s.cnt * 0.75 then 'A2' else 'A3' end end
   from s where p.id = s.id;
  update app_settings set value = cur::text where key = 'pr_month';
end $$;

-- はじめて動かすとき：選手とモーターをそろえ、きのうの分を走らせて成績をつくる
create or replace function public._pr_seed() returns void
language plpgsql volatile set search_path = public as $$
declare i int; j int; r record; d date := _kb_jday(_now()) - 1; g text; p numeric;
begin
  perform pg_advisory_xact_lock(7801);
  if exists (select 1 from pr_racers limit 1) then return; end if;
  for i in 1..180 loop
    g := case when i <= 36 then 'A1' when i <= 72 then 'A2' when i <= 162 then 'B1' else 'B2' end;
    perform _pr_new_racer('boat', g, 20 + floor(random() * 36)::int);
  end loop;
  for i in 1..200 loop
    g := case when i <= 30 then 'S1' when i <= 80 then 'S2' when i <= 130 then 'A1' when i <= 170 then 'A2' else 'A3' end;
    perform _pr_new_racer('bike', g, 20 + floor(random() * 30)::int);
  end loop;
  for r in select id from pr_venues where sport = 'boat' loop
    for j in 1..60 loop
      p := round(_kb_norm(), 3);
      insert into pr_motors(venue, no, power, r2, starts) values (r.id, j, p, round(least(60, greatest(15, 33 + 11 * p + _kb_norm() * 4)), 1), 30)
      on conflict do nothing;
    end loop;
  end loop;
  insert into app_settings values ('pr_month', _kb_midx(_now())::text) on conflict (key) do update set value = excluded.value;
  perform _pr_make_day('boat', d); perform _pr_make_day('bike', d);
  for r in select id from pr_races where day = d order by id loop perform _pr_settle(r.id); end loop;
end $$;

-- 時計：終わったレースの確定、月の変わり目、きょうの番組づくり（毎分と、画面を開いたとき）
create or replace function public._pr_tick() returns void
language plpgsql volatile set search_path = public as $$
declare r record; cur int := _kb_midx(_now()); last int; today date := _kb_jday(_now());
begin
  if not exists (select 1 from pr_racers limit 1) then perform _pr_seed(); end if;
  for r in select x.id from pr_races x
            where not x.settled and x.post + make_interval(secs => (coalesce(x.finish_ms, 0) + 15000) / 1000.0) <= _now()
            order by x.id loop
    perform _pr_settle(r.id);
  end loop;
  select value::int into last from app_settings where key = 'pr_month';
  if last is null then insert into app_settings values ('pr_month', cur::text) on conflict (key) do nothing;
  elsif last < cur then perform _pr_month(cur);
  end if;
  if not exists (select 1 from pr_races where day = today and sport = 'boat') then perform _pr_make_day('boat', today);
  elsif not exists (select 1 from pr_races where day = today and sport = 'bike') then perform _pr_make_day('bike', today);
  end if;
end $$;

-- 公開しているか（app_settings 'beta_games' に boat があるあいだは管理者だけ）
create or replace function public._pr_open(u uuid) returns boolean
language sql stable set search_path = public as $$ select _beta_ok(u, 'boat') $$;

-- きょうの番組（p_sport：boat 競艇・bike 競輪）
create or replace function public.pr_day(p_sport text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); today date;
begin
  if not _pr_open(u) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  if coalesce(p_sport, '') not in ('boat', 'bike') then raise exception '競艇か競輪をえらんでください'; end if;
  perform _pr_tick();
  today := _kb_jday(_now());
  return jsonb_build_object('now_ms', _kb_ms(_now()), 'day', today, 'sport', p_sport,
    'races', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'no', r.no, 'rnum', r.rnum, 'sess', r.sess, 'post_ms', _kb_ms(r.post),
        'venue', v.name, 'title', r.title, 'name', r.name, 'cls', r.cls, 'n', r.n, 'weather', r.weather, 'status', _pr_status(r),
        'finish_ms', case when r.post <= _now() then r.finish_ms end,
        'winner', case when r.settled then (select jsonb_build_object('num', e.num, 'name', p.name, 'name_en', p.name_en, 'ninki', e.ninki)
                                              from pr_entries e join pr_racers p on p.id = e.racer_id where e.race_id = r.id and e.pos = 1) end,
        'mine', (select count(*) from pr_tickets t where t.race_id = r.id and t.user_id = u)) order by r.post), '[]'::jsonb)
      from pr_races r join pr_venues v on v.id = r.venue where r.day = today and r.sport = p_sport),
    'balance', _bal(u));
end $$;

-- 1レース分（出走表・オッズ・自分の券。発走のあとは走り、確定のあとは払戻）
create or replace function public.pr_race(p_race bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r pr_races; v pr_venues; started boolean; ent jsonb; pays jsonb := '[]'::jsonb; mine jsonb; res int[]; wk int[];
        cur int := _kb_midx(_now()); s int[]; k text;
begin
  if not _pr_open(u) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  perform _pr_tick();
  select * into r from pr_races where id = p_race;
  if not found then raise exception 'レースが見つかりません'; end if;
  select * into v from pr_venues where id = r.venue;
  started := r.post <= _now();
  select jsonb_agg(jsonb_build_object(
      'num', e.num, 'waku', e.waku, 'course', e.course, 'line', e.line, 'lpos', e.lpos, 'ninki', e.ninki, 'odds_win', e.odds_win,
      'id', p.id, 'name', p.name, 'name_en', p.name_en, 'regno', p.regno, 'term', p.term, 'grade', p.grade, 'pref', p.pref, 'area', p.area,
      'age', cur - p.born, 'style', p.style, 'rate', p.rate, 'r2', p.r2, 'r3', p.r3, 'st_avg', p.st_avg, 'f', p.f_count,
      'motor', e.motor, 'motor_r2', (select m.r2 from pr_motors m where m.venue = r.venue and m.no = e.motor),
      'last5', (select coalesce(jsonb_agg(jsonb_build_object('pos', x.pos, 'inc', x.incident, 'n', x.n) order by x.race_id desc), '[]'::jsonb)
                  from (select e2.race_id, e2.pos, e2.incident, r2.n from pr_entries e2 join pr_races r2 on r2.id = e2.race_id
                         where e2.racer_id = p.id and e2.race_id < r.id and r2.settled order by e2.race_id desc limit 5) x),
      'run', case when started then jsonb_build_object('pos', e.pos, 'st', e.st, 'time_ms', e.time_ms, 'margin', e.margin, 'last', e.last,
                                                       'inc', e.incident, 'inc_val', e.inc_val) end
    ) order by e.num) into ent
    from pr_entries e join pr_racers p on p.id = e.racer_id where e.race_id = r.id;
  if r.settled then
    select coalesce(array_agg(num order by pos), '{}') into res from pr_entries where race_id = r.id and pos is not null;
    select array_agg(waku order by num) into wk from pr_entries where race_id = r.id;
    if cardinality(res) >= 3 then
      if r.sport = 'boat' then
        pays := pays || jsonb_build_object('kind', 'tan', 'sel', array[res[1]], 'odds', _pr_odds(r.id, 'tan', array[res[1]]))
                     || jsonb_build_object('kind', 'fuku', 'sel', array[res[1]], 'odds', _pr_odds(r.id, 'fuku', array[res[1]]))
                     || jsonb_build_object('kind', 'fuku', 'sel', array[res[2]], 'odds', _pr_odds(r.id, 'fuku', array[res[2]]));
      end if;
      pays := pays || jsonb_build_object('kind', 'ex2', 'sel', res[1:2], 'odds', _pr_odds(r.id, 'ex2', res[1:2]));
      s := array[least(res[1], res[2]), greatest(res[1], res[2])];
      pays := pays || jsonb_build_object('kind', 'qn2', 'sel', s, 'odds', _pr_odds(r.id, 'qn2', s));
      foreach s slice 1 in array array[[least(res[1], res[2]), greatest(res[1], res[2])], [least(res[1], res[3]), greatest(res[1], res[3])],
                                       [least(res[2], res[3]), greatest(res[2], res[3])]] loop
        pays := pays || jsonb_build_object('kind', 'wide', 'sel', s, 'odds', _pr_odds(r.id, 'wide', s));
      end loop;
      pays := pays || jsonb_build_object('kind', 'ex3', 'sel', res[1:3], 'odds', _pr_odds(r.id, 'ex3', res[1:3]));
      select array_agg(z order by z) into s from unnest(res[1:3]) z;
      pays := pays || jsonb_build_object('kind', 'tr3', 'sel', s, 'odds', _pr_odds(r.id, 'tr3', s));
      if r.sport = 'bike' and r.n >= 9 then
        pays := pays || jsonb_build_object('kind', 'wex', 'sel', array[wk[res[1]], wk[res[2]]], 'odds', _pr_odds(r.id, 'wex', array[wk[res[1]], wk[res[2]]]));
        s := array[least(wk[res[1]], wk[res[2]]), greatest(wk[res[1]], wk[res[2]])];
        pays := pays || jsonb_build_object('kind', 'wqn', 'sel', s, 'odds', _pr_odds(r.id, 'wqn', s));
      end if;
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('kind', t.kind, 'sel', t.sel, 'amount', t.amount, 'odds', t.odds, 'payout', t.payout, 'refund', t.refund) order by t.id), '[]'::jsonb)
    into mine from pr_tickets t where t.race_id = r.id and t.user_id = u;
  return jsonb_build_object('now_ms', _kb_ms(_now()),
    'race', jsonb_build_object('id', r.id, 'sport', r.sport, 'no', r.no, 'rnum', r.rnum, 'day', r.day, 'sess', r.sess, 'post_ms', _kb_ms(r.post),
      'status', _pr_status(r), 'title', r.title, 'name', r.name, 'cls', r.cls, 'n', r.n, 'weather', r.weather, 'wind', r.wind, 'wave', r.wave,
      'venue', jsonb_build_object('name', v.name, 'water', v.water, 'bank', v.bank, 'straight', v.straight),
      'finish_ms', case when started then r.finish_ms end, 'kimarite', case when started then r.kimarite end,
      'plan', case when started then r.plan end,
      'lines', case when r.sport = 'bike' then (select jsonb_agg(z.m order by z.l) from (select line l, jsonb_agg(num order by lpos) m from pr_entries where race_id = r.id group by line) z) end,
      'rates', jsonb_build_object('tan', _pr_rate('tan'), 'ex3', _pr_rate('ex3'))),
    'entries', coalesce(ent, '[]'::jsonb), 'payouts', pays, 'mine', mine, 'balance', _bal(u));
end $$;

-- 買う前にオッズを見る
create or replace function public.pr_odds(p_race bigint, p_kind text, p_sel int[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); s int[];
begin
  if not _pr_open(u) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  s := _pr_check_sel(p_race, p_kind, p_sel);
  return jsonb_build_object('sel', s, 'odds', _pr_odds(p_race, p_kind, s));
end $$;

-- 券を買う（オッズは買った時点で決まる）
create or replace function public.pr_bet(p_race bigint, p_kind text, p_sel int[], p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); r pr_races; s int[]; od numeric;
begin
  if not _pr_open(u) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  perform _pr_tick();
  select * into r from pr_races where id = p_race;
  if not found then raise exception 'レースが見つかりません'; end if;
  if _now() >= r.post - interval '60 seconds' then raise exception 'このレースの発売は締め切りました'; end if;
  s := _pr_check_sel(p_race, p_kind, p_sel);
  od := _pr_odds(p_race, p_kind, s);
  perform _take(u, p_amount);
  insert into pr_tickets(race_id, user_id, kind, sel, amount, odds) values (p_race, u, p_kind, s, p_amount, od);
  return jsonb_build_object('odds', od, 'sel', s,
    'mine', (select coalesce(jsonb_agg(jsonb_build_object('kind', t.kind, 'sel', t.sel, 'amount', t.amount, 'odds', t.odds, 'payout', t.payout, 'refund', t.refund) order by t.id), '[]'::jsonb)
               from pr_tickets t where t.race_id = p_race and t.user_id = u),
    'balance', _bal(u));
end $$;

-- 選手のくわしい成績
create or replace function public.pr_racer(p_id int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); p pr_racers;
begin
  if not _pr_open(u) then raise exception '準備中です。もうしばらくお待ちください'; end if;
  select * into p from pr_racers where id = p_id;
  if not found then raise exception '選手が見つかりません'; end if;
  return jsonb_build_object('id', p.id, 'sport', p.sport, 'name', p.name, 'name_en', p.name_en, 'regno', p.regno, 'term', p.term, 'grade', p.grade,
    'pref', p.pref, 'area', p.area, 'age', _kb_midx(_now()) - p.born, 'style', p.style, 'rate', p.rate, 'r2', p.r2, 'r3', p.r3, 'st_avg', p.st_avg,
    'f', p.f_count, 'starts', p.starts, 'wins', p.wins, 'seconds', p.seconds, 'thirds', p.thirds, 'retired', p.retired,
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('day', r.day, 'venue', v.name, 'rnum', r.rnum, 'name', r.name, 'n', r.n, 'num', e.num,
                 'pos', e.pos, 'st', e.st, 'inc', e.incident, 'ninki', e.ninki, 'kimarite', case when e.pos = 1 then r.kimarite end) order by r.id desc), '[]'::jsonb)
               from (select * from pr_entries where racer_id = p.id order by race_id desc limit 30) e
               join pr_races r on r.id = e.race_id join pr_venues v on v.id = r.venue where r.settled));
end $$;

-- 毎分：確定・番組づくり（pg_cron があるとき）
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-pr', '* * * * *', 'select public._pr_tick()');
  end if;
end $$;

-- =====================================================================
-- 釣り（風の芽製作所）：ひとりで釣る＋毎日の釣り大会。釣った魚は競り市に出して売る
--   釣り場：堤防・磯・沖（船）・川・湖。季節（春夏秋冬）と時間帯（朝まずめ・日中・夕まずめ・夜）で釣れる魚がかわる
--   1回投げるごとにエサ代。アタリ（浮きがしずむ）で「合わせる」→ やりとり（あばれたらゆるめ、休んだら巻く）→ 釣り上げたら、いけすへ
--   いけすの魚は競り市に出す（出品）。競り市（魚市場・まぜた市）が始まると、出品した魚が品になって競られ、売れた額（手数料5%をのぞく）を受け取る
--   12時間たっても売れない出品と、2日たったいけすの魚は、仲卸が引き取る（7割・5割）
--   釣り大会：毎日16:00〜16:20（夕まずめ）。参加費100 X。いちばん重い1匹で順位。参加費の95%を1〜3位で分ける（50・30・20%）
--   やりとりは、決まった手順で（サーバーと画面で同じ計算）：50msごとに、巻いているか・魚の力から、糸の張り（0〜1000）と距離を計算
-- =====================================================================
create table if not exists public.fi_casts (
  id        bigserial primary key,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  spot      text not null,
  cost      bigint not null,
  at        timestamptz not null default now(),
  bite_ms   int,                                  -- アタリまで（null＝アタリなし）
  window_ms int,
  nib       int[] not null default '{}',          -- 小さなアタリ（合わせると早合わせ）
  fish      jsonb,                                -- 決まった魚（見せるのは釣り上げたあと）
  fight     jsonb,                                -- やりとりの決まり（合わせたあと）
  state     text not null default 'wait',         -- wait / fight / landed / lost
  hook_at   timestamptz,
  result    text,
  tourney   date                                  -- 大会のあいだに大会の釣り場で投げた
);
create index if not exists fi_casts_user on public.fi_casts(user_id, id desc);
create index if not exists fi_casts_open on public.fi_casts(state) where state in ('wait', 'fight');
create table if not exists public.fi_catches (
  id       bigserial primary key,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  spot     text not null,
  sp       text not null,                        -- 魚の種類
  nm       text not null,
  em       text not null,
  len      numeric not null,                     -- cm
  kg       numeric not null,
  v_est    bigint not null,                      -- 値打ちの目安
  v        bigint not null,                      -- 本当の値打ち（売れるまで見せない）
  at       timestamptz not null default now(),
  status   text not null default 'keep',         -- keep いけす / lot 出品 / sold 売れた / wholesale 仲卸
  lot_id   bigint,
  tourney  date
);
create index if not exists fi_catches_user on public.fi_catches(user_id, status);
create index if not exists fi_catches_at on public.fi_catches(at);
create table if not exists public.fi_lots (
  id       bigserial primary key,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  nm       text not null,
  em       text not null,
  info     text not null,
  n        int not null,
  kg       numeric not null,
  v        bigint not null,                      -- 本当の値打ち（合計）
  e0       bigint not null,                      -- 目安（合計）
  status   text not null default 'queued',       -- queued 出品中 / auction 競り中 / sold 売れた / wholesale 仲卸
  room_id  bigint,
  price    bigint,
  net      bigint,
  at       timestamptz not null default now(),
  sold_at  timestamptz
);
create index if not exists fi_lots_q on public.fi_lots(status, at);
create index if not exists fi_lots_user on public.fi_lots(user_id, id desc);
create table if not exists public.fi_tourneys (
  day      date primary key,
  spot     text not null,
  start_at timestamptz not null,
  end_at   timestamptz not null,
  fee      bigint not null,
  status   text not null default 'open',         -- open / done
  result   jsonb
);
create table if not exists public.fi_entries (
  day      date not null references public.fi_tourneys(day),
  user_id  uuid not null references public.profiles(id) on delete cascade,
  paid     bigint not null,
  best_kg  numeric,
  best_len numeric,
  best_nm  text,
  best_at  timestamptz,
  prize    bigint,
  primary key (day, user_id)
);
alter table public.fi_casts    enable row level security;
alter table public.fi_catches  enable row level security;
alter table public.fi_lots     enable row level security;
alter table public.fi_tourneys enable row level security;
alter table public.fi_entries  enable row level security;
revoke all on public.fi_casts, public.fi_catches, public.fi_lots, public.fi_tourneys, public.fi_entries from anon, authenticated;

-- 魚の表（spot 釣り場, k 種類, nm 名前, em 絵, seas 季節（春1・夏2・秋4・冬8）, tod 時間帯（朝まずめ1・日中2・夕まずめ4・夜8）, w 釣れやすさ,
--   lmin/lmed/lmax 長さ（cm）, kgm lmed のときの重さ（kg）, ppk 1kgの値段（X）, pw 力, st 粘り（あばれる回数）, win 合わせの猶予（ms））
create or replace function public._fi_species()
returns table(spot text, k text, nm text, em text, seas int, tod int, w numeric, lmin numeric, lmed numeric, lmax numeric, kgm numeric, ppk numeric, pw int, st int, win int)
language sql immutable as $$
  select * from (values
    ('pier','aji','マアジ','🐟',15,15,30,12,20,34,0.1,84.0,22,2,1300),
    ('pier','saba','マサバ','🐟',14,7,18,18,28,42,0.28,52.5,38,3,1300),
    ('pier','iwashi','カタクチイワシ','🐟',15,7,14,8,11,15,0.012,42.0,8,1,1500),
    ('pier','kisu','シロギス','🐟',7,7,12,12,18,28,0.06,262.5,15,1,1100),
    ('pier','haze','マハゼ','🐟',6,7,12,8,13,20,0.025,157.5,8,1,1300),
    ('pier','kasago','カサゴ','🐟',15,15,8,12,19,30,0.13,210.0,22,2,1100),
    ('pier','mebaru','メバル','🐟',9,13,8,12,20,32,0.15,210.0,20,2,1000),
    ('pier','kurodai','クロダイ','🐟',15,13,4,25,38,55,1.0,105.0,55,4,900),
    ('pier','suzuki','スズキ','🐟',15,13,4,35,55,90,1.8,126.0,60,4,1000),
    ('pier','aori','アオリイカ','🦑',5,13,4,15,25,45,0.8,315.0,45,3,1200),
    ('pier','tachiuo','タチウオ','🐟',4,12,6,70,95,130,0.5,157.5,40,3,900),
    ('pier','bora','ボラ','🐟',15,15,6,30,45,65,1.0,21.0,50,3,1300),
    ('rock','mejina','メジナ','🐟',15,7,30,20,30,50,0.5,95.3,50,3,900),
    ('rock','budai','ブダイ','🐟',12,2,10,25,35,50,0.8,57.2,40,3,1100),
    ('rock','kawahagi','カワハギ','🐟',12,2,12,15,22,30,0.25,285.9,20,2,800),
    ('rock','ishidai','イシダイ','🐟',6,7,6,30,45,65,1.8,285.9,70,5,900),
    ('rock','ishigaki','イシガキダイ','🐟',6,7,4,30,45,70,2.0,238.2,70,5,900),
    ('rock','warasa','ワラサ','🐟',12,5,6,50,65,85,3.0,95.3,75,5,1100),
    ('rock','hiramasa','ヒラマサ','🐟',6,5,3,60,80,120,5.0,190.6,85,6,1000),
    ('rock','akahata','アカハタ','🐟',6,6,8,20,30,45,0.5,238.2,40,3,1000),
    ('rock','kurodai','クロダイ','🐟',15,13,4,25,38,55,1.0,95.3,55,4,900),
    ('off','madai','マダイ','🐟',15,7,25,25,40,80,1.0,202.4,50,4,1000),
    ('off','hirame','ヒラメ','🐟',12,7,12,35,50,85,1.4,303.6,55,4,900),
    ('off','buri','ブリ','🐟',12,7,12,70,85,105,7.0,121.4,85,6,1000),
    ('off','kanpachi','カンパチ','🐟',6,7,8,50,70,110,4.0,253.0,85,6,1000),
    ('off','katsuo','カツオ','🐟',3,7,12,40,50,70,2.5,81.0,75,5,1200),
    ('off','kihada','キハダ','🐟',6,7,4,70,100,150,15,151.8,95,8,1000),
    ('off','maguro','本マグロ','🐟',12,5,0.4,120,165,250,70,506.0,100,12,900),
    ('off','amadai','アマダイ','🐟',13,7,10,25,35,50,0.6,404.8,30,2,1000),
    ('off','aji','マアジ','🐟',15,7,20,20,28,40,0.25,81.0,25,2,1300),
    ('off','kue','クエ','🐟',15,14,1,50,70,110,6,607.2,95,8,900),
    ('off','nodoguro','ノドグロ','🐟',15,2,4,20,28,40,0.4,607.2,25,2,1000),
    ('river','ayu','アユ','🐟',6,2,25,15,20,28,0.08,331.8,25,2,1000),
    ('river','oikawa','オイカワ','🐟',15,7,20,8,12,16,0.02,110.6,10,1,1200),
    ('river','ugui','ウグイ','🐟',15,15,20,15,25,40,0.15,33.2,25,2,1200),
    ('river','yamame','ヤマメ','🐟',3,7,10,15,22,32,0.12,331.8,30,2,900),
    ('river','iwana','イワナ','🐟',7,7,8,18,26,45,0.2,331.8,35,3,900),
    ('river','koi','コイ','🐟',15,15,10,40,60,90,3.0,33.2,70,5,1300),
    ('river','namazu','ナマズ','🐟',6,12,6,35,50,70,1.2,55.3,55,4,1200),
    ('river','unagi','ウナギ','🐟',6,8,4,40,55,80,0.25,663.6,45,3,1000),
    ('river','sakuramasu','サクラマス','🐟',1,5,1,40,55,70,2.0,442.4,75,6,900),
    ('lake','bass','ブラックバス','🐟',7,5,25,25,35,55,0.7,30.7,50,4,1000),
    ('lake','gill','ブルーギル','🐟',6,15,20,10,15,22,0.08,10.2,12,1,1300),
    ('lake','hera','ヘラブナ','🐟',15,7,20,25,35,48,0.8,41.0,40,3,800),
    ('lake','wakasagi','ワカサギ','🐟',8,7,30,7,10,14,0.008,410.0,6,1,1100),
    ('lake','niji','ニジマス','🐟',15,7,12,25,35,55,0.5,153.8,45,3,1000),
    ('lake','himemasu','ヒメマス','🐟',6,5,6,20,28,38,0.25,307.5,30,2,1000),
    ('lake','raigyo','ライギョ','🐟',2,7,5,50,65,90,2.0,30.7,70,5,1100),
    ('lake','ito','イトウ','🐟',5,13,0.3,70,95,140,8.0,512.5,95,9,900)
  ) x(spot, k, nm, em, seas, tod, w, lmin, lmed, lmax, kgm, ppk, pw, st, win)
$$;

-- 釣り場（名前・絵・エサ代・はじめの距離（cm））
create or replace function public._fi_spot(s text) returns jsonb
language sql immutable as $$
  select case s
    when 'pier'  then '{"k":"pier","nm":"堤防","em":"🌊","cost":25,"d0":1500}'::jsonb
    when 'rock'  then '{"k":"rock","nm":"磯","em":"🪨","cost":100,"d0":2000}'::jsonb
    when 'off'   then '{"k":"off","nm":"沖（船）","em":"🚢","cost":400,"d0":3000}'::jsonb
    when 'river' then '{"k":"river","nm":"川","em":"🏞","cost":30,"d0":1200}'::jsonb
    when 'lake'  then '{"k":"lake","nm":"湖","em":"🛶","cost":40,"d0":1800}'::jsonb
  end
$$;
create or replace function public._fi_spots() returns text[]
language sql immutable as $$ select array['pier', 'rock', 'off', 'river', 'lake'] $$;

-- 時間帯（日本時間）：朝まずめ 4:30〜7:30・日中 〜16:00・夕まずめ 〜19:00・夜
create or replace function public._fi_tod(ts timestamptz) returns int
language sql stable as $$
  select case when m >= 270 and m < 450 then 1 when m >= 450 and m < 960 then 2 when m >= 960 and m < 1140 then 4 else 8 end
    from (select extract(hour from ts at time zone 'Asia/Tokyo')::int * 60 + extract(minute from ts at time zone 'Asia/Tokyo')::int m) z
$$;
create or replace function public._fi_season(ts timestamptz) returns int
language sql stable as $$
  select case when mo between 3 and 5 then 1 when mo between 6 and 8 then 2 when mo between 9 and 11 then 4 else 8 end
    from (select extract(month from ts at time zone 'Asia/Tokyo')::int mo) z
$$;
-- 文字から決まる正規乱数（その日の魚の相場に使う）
create or replace function public._fi_hnorm(t text) returns double precision
language sql immutable as $$
  select sqrt(-2 * ln(greatest(1e-9, ('x' || substr(h, 1, 8))::bit(32)::bigint::double precision / 4294967296.0)))
         * cos(2 * pi() * (('x' || substr(h, 9, 8))::bit(32)::bigint::double precision / 4294967296.0))
    from (select md5(t) h) z
$$;
-- その日の相場（魚ごと。平均がほぼ1）
create or replace function public._fi_market(sp text, d date) returns numeric
language sql immutable as $$ select exp(0.15 * _fi_hnorm(sp || ':' || d::text) - 0.0112)::numeric $$;

-- 魚を決める（5%はゴミ）
create or replace function public._fi_pick(s text, ts timestamptz) returns jsonb
language plpgsql volatile set search_path = public as $$
declare r record; t int := _fi_tod(ts); se int := _fi_season(ts); L numeric; kg numeric; ve bigint; v bigint; j record;
begin
  if random() < 0.05 then
    select * into j from (values ('boot', '長靴', '👢'), ('can', '空き缶', '🥫'), ('wood', '流木', '🪵'),
                                 ('weed', '海藻', '🌿')) x(k, nm, em)
     where x.k <> 'weed' or s in ('pier', 'rock', 'off') order by random() limit 1;
    return jsonb_build_object('junk', true, 'sp', j.k, 'nm', j.nm, 'em', j.em, 'pw', 3, 'st', 0, 'win', 1500, 'kg', 0.5, 'kgm', 0.5);
  end if;
  select * into r from _fi_species() f
   where f.spot = s and (f.seas & se) > 0
   order by -ln(1 - random()) / (f.w * case when (f.tod & t) > 0 then 1 else 0.2 end) limit 1;
  L := r.lmed * exp(_randn() * 0.18) * case when random() < 0.03 then 1.25 else 1 end;
  L := round(least(r.lmax, greatest(r.lmin, L)), 1);
  kg := round(r.kgm * power(L / r.lmed, 3), 3);
  ve := greatest(1, round(r.ppk * kg * sqrt(L / r.lmed)))::bigint;
  v := greatest(1, round(ve * _fi_market(r.k, _kb_jday(ts)) * exp(_randn() * 0.08 - 0.0032)))::bigint;
  return jsonb_build_object('junk', false, 'sp', r.k, 'nm', r.nm, 'em', r.em, 'len', L, 'kg', kg, 'v_est', ve, 'v', v,
                            'pw', r.pw, 'st', r.st, 'win', r.win, 'kgm', r.kgm);
end $$;

-- やりとりの決まり：魚の力・あばれる回数から、あばれる（強く引く）と休むのくり返し（[50msの回数, 力]）
create or replace function public._fi_fight(f jsonb, s text) returns jsonb
language plpgsql volatile as $$
declare P int; nr int; i int; segs jsonb := '[]'; ratio numeric := greatest(0.05, (f->>'kg')::numeric / greatest(0.001, (f->>'kgm')::numeric));
begin
  if coalesce((f->>'junk')::boolean, false) then
    return jsonb_build_object('d0', round((_fi_spot(s)->>'d0')::int * 0.6), 'segs', '[]'::jsonb, 'tired', 3, 'tmax', 2400);
  end if;
  P := least(100, greatest(5, round((f->>'pw')::int * power(ratio, 0.35))))::int;
  nr := least(14, greatest(1, (f->>'st')::int + round(ln(1 + ratio) / ln(2))::int - 1));
  for i in 0..nr - 1 loop
    segs := segs || jsonb_build_array(jsonb_build_array(10 + floor(random() * 18)::int + P / 8, least(100, round(P * (0.85 + random() * 0.15) * (1 - 0.035 * i))::int)));
    segs := segs || jsonb_build_array(jsonb_build_array(16 + floor(random() * 24)::int, round(P * (0.10 + random() * 0.08))::int + 4));
  end loop;
  return jsonb_build_object('d0', round((_fi_spot(s)->>'d0')::int * (0.9 + random() * 0.2))::int, 'segs', segs,
                            'tired', greatest(4, round(P * 0.06))::int, 'tmax', 2400);
end $$;

-- やりとりの計算（画面の fiSim と同じ。整数だけ）。tg：巻く・ゆるめるを切りかえた時刻（50ms の回数）
create or replace function public._fi_sim(fg jsonb, tg int[]) returns jsonb
language plpgsql immutable as $$
declare d int := (fg->>'d0')::int; d0 int := (fg->>'d0')::int; tm int := (fg->>'tmax')::int; tired int := (fg->>'tired')::int;
        segs jsonb := fg->'segs'; ns int := jsonb_array_length(fg->'segs'); si int := 0; lft int; k int; ti int := 1; nt int := coalesce(cardinality(tg), 0);
        hold boolean := false; f int; tg2 int; t int := 0; slack int := 0;
begin
  lft := case when ns > 0 then (segs->0->>0)::int else 0 end;
  for k in 0..tm - 1 loop
    while ti <= nt and tg[ti] <= k loop hold := not hold; ti := ti + 1; end loop;
    f := case when si < ns then (segs->si->>1)::int else tired end;
    if hold then
      tg2 := 100 + 11 * f; t := t + (tg2 - t) / 8; d := d - (15 * (100 - f)) / 100;
    else
      tg2 := 2 * f; t := t + (tg2 - t) / 4; d := d + (10 * f) / 100;
    end if;
    if si < ns then
      lft := lft - 1;
      if lft <= 0 then si := si + 1; lft := case when si < ns then (segs->si->>0)::int else 0 end; end if;
    end if;
    if t >= 1000 then return jsonb_build_object('res', 'break', 'k', k); end if;
    if not hold and t < 120 then slack := slack + 1; else slack := 0; end if;
    if slack >= 50 then return jsonb_build_object('res', 'spit', 'k', k); end if;
    if d <= 0 then return jsonb_build_object('res', 'landed', 'k', k); end if;
    if d >= d0 + 3000 then return jsonb_build_object('res', 'run', 'k', k); end if;
  end loop;
  return jsonb_build_object('res', 'timeout', 'k', tm);
end $$;

-- 釣り大会（毎日16:00〜16:20。釣り場は曜日で：月 堤防・火 川・水 磯・木 湖・金 堤防・土 沖・日 磯）
create or replace function public._fi_tourney(d date) returns fi_tourneys
language plpgsql volatile set search_path = public as $$
declare t fi_tourneys; s text;
begin
  select * into t from fi_tourneys where day = d;
  if found then return t; end if;
  s := (array['pier', 'river', 'rock', 'lake', 'pier', 'off', 'rock'])[extract(isodow from d)::int];
  insert into fi_tourneys(day, spot, start_at, end_at, fee)
  values (d, s, make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 16, 0, 0, 'Asia/Tokyo'),
          make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 16, 20, 0, 'Asia/Tokyo'), 100)
  on conflict (day) do nothing;
  select * into t from fi_tourneys where day = d;
  return t;
end $$;

-- 大会の精算（参加費の95%を、いちばん重い1匹の順に 50・30・20%。釣れた人がいなければ、ひとりだけなら、参加費を返す）
create or replace function public._fi_settle(d date) returns void
language plpgsql volatile set search_path = public as $$
declare t fi_tourneys; e record; n int; nf int; pool bigint; sh numeric[] := array[0.5, 0.3, 0.2]; i int := 0; pz bigint; given bigint := 0; ids uuid[] := '{}';
        board jsonb;
begin
  select * into t from fi_tourneys where day = d for update;
  if not found or t.status <> 'open' then return; end if;
  select count(*), count(best_kg), coalesce(sum(paid), 0) into n, nf, pool from fi_entries where day = d;
  board := (select coalesce(jsonb_agg(jsonb_build_object('nick', p.nickname, 'kg', x.best_kg, 'len', x.best_len, 'nm', x.best_nm) order by x.best_kg desc, x.best_at), '[]'::jsonb)
              from (select * from fi_entries where day = d and best_kg is not null order by best_kg desc, best_at limit 10) x join profiles p on p.id = x.user_id);
  if n <= 1 or nf = 0 then
    for e in select * from fi_entries where day = d loop
      perform _give(e.user_id, e.paid);
      perform _log(e.user_id, 'fishing', 0, e.paid, jsonb_build_object('tourney', d, 'refund', true));
      update fi_entries set prize = 0 where day = d and user_id = e.user_id;
      perform _notice(e.user_id, format('【釣り大会】%s の夕まずめ釣り大会は、%s ので参加費 %s X を返しました。', to_char(d, 'FMMM月FMDD日'),
                      case when n <= 1 then '参加者がひとりだった' else 'だれも釣れなかった' end, _fmt(e.paid)));
    end loop;
  else
    pool := floor(pool * 0.95);
    for e in select * from fi_entries where day = d and best_kg is not null order by best_kg desc, best_at loop
      i := i + 1;
      exit when i > 3;
      pz := floor(pool * (case when i = 1 then sh[1] + (case when nf < 2 then sh[2] else 0 end) + (case when nf < 3 then sh[3] else 0 end) else sh[i] end));
      given := given + pz;
      perform _give(e.user_id, pz);
      perform _log(e.user_id, 'fishing', 0, pz, jsonb_build_object('tourney', d, 'rank', i));
      update fi_entries set prize = pz where day = d and user_id = e.user_id;
      ids := ids || e.user_id;
      perform _notice(e.user_id, format('【釣り大会】%s の夕まずめ釣り大会で %s位 に入りました（%s %s kg）。賞金 %s X を受け取りました。',
                      to_char(d, 'FMMM月FMDD日'), i, e.best_nm, round(e.best_kg, 2), _fmt(pz)));
    end loop;
    for e in select * from fi_entries where day = d and not (user_id = any(ids)) loop
      update fi_entries set prize = 0 where day = d and user_id = e.user_id;
      perform _notice(e.user_id, format('【釣り大会】%s の夕まずめ釣り大会が終わりました。%s', to_char(d, 'FMMM月FMDD日'),
                      case when e.best_kg is null then '今回は釣れませんでした。' else format('あなたの記録：%s %s kg', e.best_nm, round(e.best_kg, 2)) end));
    end loop;
  end if;
  update fi_tourneys set status = 'done', result = jsonb_build_object('n', n, 'board', board) where day = d;
end $$;

-- 仲卸が引き取る（出品して12時間たっても売れない → 値打ちの7割、いけすで2日たった魚 → 5割）
create or replace function public._fi_wholesale() returns void
language plpgsql volatile set search_path = public as $$
declare l record; c record; amt bigint;
begin
  for l in select * from fi_lots where status = 'queued' and at < _now() - interval '12 hours' for update skip locked loop
    amt := greatest(1, round(l.v * 0.7))::bigint;
    perform _give(l.user_id, amt);
    perform _log(l.user_id, 'fishing', 0, amt, jsonb_build_object('lot', l.id, 'wholesale', true));
    update fi_lots set status = 'wholesale', price = amt, net = amt, sold_at = _now() where id = l.id;
    update fi_catches set status = 'wholesale' where lot_id = l.id;
    perform _notice(l.user_id, format('【釣り】出品した「%s」は12時間たっても競りがなかったので、仲卸が %s X で引き取りました。', l.nm, _fmt(amt)));
  end loop;
  for c in select user_id, count(*) n, sum(greatest(1, round(v * 0.5)))::bigint s, array_agg(id) ids from fi_catches
            where status = 'keep' and at < _now() - interval '2 days' group by user_id loop
    perform _give(c.user_id, c.s);
    perform _log(c.user_id, 'fishing', 0, c.s, jsonb_build_object('wholesale', true, 'n', c.n));
    update fi_catches set status = 'wholesale' where id = any(c.ids);
    perform _notice(c.user_id, format('【釣り】いけすで2日たった魚 %s匹を、仲卸が %s X で引き取りました。', c.n, _fmt(c.s)));
  end loop;
end $$;

-- 毎分：きょうの大会をつくる・終わった大会の精算・仲卸・放っておかれた仕掛けを片づける
create or replace function public._fi_tick() returns void
language plpgsql volatile set search_path = public as $$
declare t record;
begin
  perform _fi_tourney(_kb_jday(_now()));
  for t in select day from fi_tourneys where status = 'open' and end_at + interval '90 seconds' < _now() order by day loop
    perform _fi_settle(t.day);
  end loop;
  perform _fi_wholesale();
  update fi_casts set state = 'lost', result = coalesce(result, 'abandon') where state in ('wait', 'fight') and at < _now() - interval '10 minutes';
end $$;

-- 大会の見せかた
create or replace function public._fi_tjson(t fi_tourneys, u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('day', t.day, 'spot', t.spot, 'spot_nm', _fi_spot(t.spot)->>'nm', 'spot_em', _fi_spot(t.spot)->>'em',
    'start_ms', _kb_ms(t.start_at), 'end_ms', _kb_ms(t.end_at), 'join_until_ms', _kb_ms(t.end_at - interval '5 minutes'), 'fee', t.fee, 'status', t.status,
    'n', (select count(*) from fi_entries where day = t.day),
    'pool', (select floor(coalesce(sum(paid), 0) * 0.95) from fi_entries where day = t.day),
    'joined', exists (select 1 from fi_entries where day = t.day and user_id = u),
    'me', (select jsonb_build_object('kg', best_kg, 'len', best_len, 'nm', best_nm, 'prize', prize) from fi_entries where day = t.day and user_id = u),
    'board', (select coalesce(jsonb_agg(jsonb_build_object('nick', p.nickname, 'kg', x.best_kg, 'len', x.best_len, 'nm', x.best_nm, 'me', x.user_id = u, 'prize', x.prize)
                order by x.best_kg desc, x.best_at), '[]'::jsonb)
                from (select * from fi_entries where day = t.day and best_kg is not null order by best_kg desc, best_at limit 10) x join profiles p on p.id = x.user_id))
$$;

-- 画面に出すもの
create or replace function public.fi_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); t fi_tourneys; se int := _fi_season(_now()); td int := _fi_tod(_now()); today date := _kb_jday(_now());
begin
  if not _beta_ok(u, 'fishing') then raise exception '準備中です。もうしばらくお待ちください'; end if;
  perform _fi_tick();
  t := _fi_tourney(today);
  return jsonb_build_object('now_ms', _kb_ms(_now()), 'tod', td, 'season', se, 'balance', _bal(u), 'cap', 30,
    'spots', (select jsonb_agg(_fi_spot(s) || jsonb_build_object('fish',
                (select coalesce(jsonb_agg(jsonb_build_object('k', f.k, 'nm', f.nm, 'em', f.em, 'now', (f.tod & td) > 0) order by ((f.tod & td) > 0) desc, f.w desc), '[]'::jsonb)
                   from _fi_species() f where f.spot = s and (f.seas & se) > 0)) order by o)
              from unnest(_fi_spots()) with ordinality z(s, o)),
    'keep', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'sp', c.sp, 'nm', c.nm, 'em', c.em, 'len', c.len, 'kg', c.kg, 'v_est', c.v_est,
               'spot', c.spot, 'at_ms', _kb_ms(c.at), 'until_ms', _kb_ms(c.at + interval '2 days')) order by c.id desc), '[]'::jsonb)
             from fi_catches c where c.user_id = u and c.status = 'keep'),
    'lots', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'nm', l.nm, 'em', l.em, 'info', l.info, 'status', l.status, 'room', l.room_id,
               'price', l.price, 'net', l.net, 'at_ms', _kb_ms(l.at), 'sold_ms', _kb_ms(l.sold_at)) order by l.id desc), '[]'::jsonb)
             from (select * from fi_lots where user_id = u order by id desc limit 20) l),
    'book', (select coalesce(jsonb_agg(jsonb_build_object('k', s.k, 'nm', s.nm, 'em', s.em, 'n', coalesce(c.n, 0), 'len', c.len, 'kg', c.kg) order by s.o), '[]'::jsonb)
             from (select f.k, min(f.nm) nm, min(f.em) em, min(array_position(_fi_spots(), f.spot) * 100 + 0) o from _fi_species() f group by f.k) s
             left join (select sp, count(*) n, max(len) len, max(kg) kg from fi_catches where user_id = u group by sp) c on c.sp = s.k),
    'big', (select coalesce(jsonb_agg(jsonb_build_object('nick', p.nickname, 'nm', c.nm, 'em', c.em, 'len', c.len, 'kg', c.kg, 'spot', c.spot, 'me', c.user_id = u) order by c.kg desc), '[]'::jsonb)
            from (select * from fi_catches where at >= _now() - interval '1 day' order by kg desc limit 5) c join profiles p on p.id = c.user_id),
    'tourney', _fi_tjson(t, u),
    'last', (select jsonb_build_object('day', x.day, 'spot_nm', _fi_spot(x.spot)->>'nm', 'board', coalesce(x.result->'board', '[]'::jsonb))
             from fi_tourneys x where x.status = 'done' order by x.day desc limit 1));
end $$;

-- 投げる（エサ代をはらう）
create or replace function public.fi_cast(p_spot text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); sp jsonb := _fi_spot(p_spot); f jsonb; pb numeric; bite int; nib int[] := '{}'; i int; x int; cid bigint; t fi_tourneys; td date := null;
        last timestamptz;
begin
  if not _beta_ok(u, 'fishing') then raise exception '準備中です。もうしばらくお待ちください'; end if;
  if sp is null then raise exception '釣り場をえらんでください'; end if;
  if (select count(*) from fi_catches where user_id = u and status = 'keep') >= 30 then
    raise exception 'いけすがいっぱいです（30匹まで）。競り市に出してから、また釣ってください';
  end if;
  select max(at) into last from fi_casts where user_id = u;
  if last is not null and last > _now() - interval '1500 milliseconds' then raise exception 'すこし待ってから投げてください'; end if;
  update fi_casts set state = 'lost', result = coalesce(result, 'abandon') where user_id = u and state in ('wait', 'fight');
  perform _take(u, (sp->>'cost')::bigint);
  perform _log(u, 'fishing', (sp->>'cost')::bigint, 0, jsonb_build_object('spot', p_spot));
  t := _fi_tourney(_kb_jday(_now()));
  if t.spot = p_spot and _now() >= t.start_at and _now() < t.end_at and exists (select 1 from fi_entries where day = t.day and user_id = u) then td := t.day; end if;
  pb := case when _fi_tod(_now()) in (1, 4) then 0.88 else 0.78 end;
  if random() < pb then
    f := _fi_pick(p_spot, _now());
    bite := 2500 + least(12500, floor(-ln(1 - random()) * 4500))::int;
    x := 700;
    for i in 1..floor(random() * 3.2)::int loop
      x := x + 700 + floor(random() * 2500)::int;
      exit when x > bite - 1200;
      nib := nib || x;
    end loop;
  end if;
  insert into fi_casts(user_id, spot, cost, at, bite_ms, window_ms, nib, fish, tourney)
  values (u, p_spot, (sp->>'cost')::bigint, _now(), bite, case when f is null then null else (f->>'win')::int end, nib, f, td)
  returning id into cid;
  return jsonb_build_object('cast', jsonb_build_object('id', cid, 'bite_ms', bite, 'window_ms', case when f is null then null else (f->>'win')::int end,
                              'nib', to_jsonb(nib), 'wait_ms', case when bite is null then 12000 end, 'tourney', td is not null),
                            'balance', _bal(u));
end $$;

-- 合わせる（p_dt：浮きがしずんでから押すまで ms。しずむ前に押したら -1）
create or replace function public.fi_hook(p_cast bigint, p_dt int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); c fi_casts; el bigint; why text; fg jsonb;
begin
  if not _beta_ok(u, 'fishing') then raise exception '準備中です。もうしばらくお待ちください'; end if;
  select * into c from fi_casts where id = p_cast and user_id = u for update;
  if not found then raise exception '仕掛けが見つかりません'; end if;
  if c.state <> 'wait' then raise exception 'この仕掛けはもう終わっています'; end if;
  el := _kb_ms(_now()) - _kb_ms(c.at);
  if c.bite_ms is null then why := 'nobite';
  elsif p_dt is null or p_dt < 0 or el < c.bite_ms - 400 then why := 'early';
  elsif p_dt > c.window_ms + 300 or el > c.bite_ms + c.window_ms + 20000 then why := 'late';
  end if;
  if why is not null then
    update fi_casts set state = 'lost', result = why where id = c.id;
    return jsonb_build_object('ok', false, 'why', why);
  end if;
  fg := _fi_fight(c.fish, c.spot);
  update fi_casts set state = 'fight', hook_at = _now(), fight = fg where id = c.id;
  return jsonb_build_object('ok', true, 'fight', fg, 'junk', coalesce((c.fish->>'junk')::boolean, false));
end $$;

-- やりとりの結果（p_ticks：巻く・ゆるめるを切りかえた時刻（50ms の回数））
create or replace function public.fi_land(p_cast bigint, p_ticks int[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); c fi_casts; r jsonb; k int; i int; f jsonb; cid bigint; t fi_tourneys; tb jsonb; nk int; e fi_entries;
begin
  if not _beta_ok(u, 'fishing') then raise exception '準備中です。もうしばらくお待ちください'; end if;
  select * into c from fi_casts where id = p_cast and user_id = u for update;
  if not found then raise exception '仕掛けが見つかりません'; end if;
  if c.state <> 'fight' then raise exception 'この仕掛けはもう終わっています'; end if;
  if coalesce(cardinality(p_ticks), 0) > 3000 then raise exception '記録が長すぎます'; end if;
  for i in 1..coalesce(cardinality(p_ticks), 0) loop
    if p_ticks[i] is null or p_ticks[i] < 0 or p_ticks[i] > (c.fight->>'tmax')::int or (i > 1 and p_ticks[i] <= p_ticks[i - 1]) then
      raise exception '記録が正しくありません';
    end if;
  end loop;
  r := _fi_sim(c.fight, coalesce(p_ticks, '{}'));
  k := (r->>'k')::int;
  if _kb_ms(_now()) - _kb_ms(c.hook_at) < k * 50 - 2500 then raise exception 'まだやりとりの途中です'; end if;
  f := c.fish;
  if r->>'res' <> 'landed' then
    update fi_casts set state = 'lost', result = r->>'res' where id = c.id;
    return jsonb_build_object('ok', false, 'why', r->>'res', 'balance', _bal(u));
  end if;
  update fi_casts set state = 'landed', result = 'landed' where id = c.id;
  if coalesce((f->>'junk')::boolean, false) then
    return jsonb_build_object('ok', true, 'junk', true, 'fish', jsonb_build_object('nm', f->>'nm', 'em', f->>'em'), 'balance', _bal(u));
  end if;
  if c.tourney is not null then
    select * into t from fi_tourneys where day = c.tourney;
    if found and _now() <= t.end_at + interval '60 seconds' then
      update fi_entries set best_kg = (f->>'kg')::numeric, best_len = (f->>'len')::numeric, best_nm = f->>'nm', best_at = _now()
       where day = t.day and user_id = u and (best_kg is null or best_kg < (f->>'kg')::numeric);
      select * into e from fi_entries where day = t.day and user_id = u;
      select count(*) + 1 into nk from fi_entries where day = t.day and best_kg is not null and (best_kg > e.best_kg or (best_kg = e.best_kg and best_at < e.best_at));
      tb := jsonb_build_object('kg', e.best_kg, 'nm', e.best_nm, 'rank', nk);
    else
      c.tourney := null;
    end if;
  end if;
  insert into fi_catches(user_id, spot, sp, nm, em, len, kg, v_est, v, at, tourney)
  values (u, c.spot, f->>'sp', f->>'nm', f->>'em', (f->>'len')::numeric, (f->>'kg')::numeric, (f->>'v_est')::bigint, (f->>'v')::bigint, _now(), c.tourney)
  returning id into cid;
  return jsonb_build_object('ok', true, 'junk', false, 'fish', jsonb_build_object('id', cid, 'sp', f->>'sp', 'nm', f->>'nm', 'em', f->>'em', 'len', (f->>'len')::numeric,
           'kg', (f->>'kg')::numeric, 'v_est', (f->>'v_est')::bigint,
           'first', (select count(*) from fi_catches where user_id = u and sp = f->>'sp') = 1,
           'best', not exists (select 1 from fi_catches where user_id = u and sp = f->>'sp' and id <> cid and len >= (f->>'len')::numeric)),
         'tourney', tb, 'keep_n', (select count(*) from fi_catches where user_id = u and status = 'keep'), 'balance', _bal(u));
end $$;

-- いけすの魚を競り市に出す（大物 300 X〜 は1匹ずつ、ほかは種類ごと。目安60 X に足りない小物は、まとめて盛り合わせ。それでも足りなければ仲卸が8割で）
create or replace function public.fi_consign(p_ids bigint[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); ids bigint[]; g record; c record; small bigint[] := '{}'; sv bigint := 0; se bigint := 0; skg numeric := 0; sn int := 0; snm text[] := '{}';
        lid bigint; amt bigint; nl int := 0;
begin
  if not _beta_ok(u, 'fishing') then raise exception '準備中です。もうしばらくお待ちください'; end if;
  ids := array(select c2.id from fi_catches c2 where c2.id = any(coalesce(p_ids, '{}')) and c2.user_id = u and c2.status = 'keep');
  if cardinality(ids) = 0 then raise exception '出す魚をえらんでください'; end if;
  if (select count(*) from fi_lots where user_id = u and status in ('queued', 'auction')) >= 12 then raise exception '出品中の品が多すぎます（12品まで）。売れてから出してください'; end if;
  -- 大物は1匹ずつ
  for c in select * from fi_catches where id = any(ids) and v_est >= 300 order by v_est desc loop
    insert into fi_lots(user_id, at, nm, em, info, n, kg, v, e0) values (u, _now(), c.nm, c.em, format('%scm・%skg・%s', c.len, round(c.kg, 2), _fi_spot(c.spot)->>'nm'), 1, c.kg, c.v, c.v_est)
    returning id into lid;
    update fi_catches set status = 'lot', lot_id = lid where id = c.id; nl := nl + 1;
  end loop;
  -- 種類ごと
  for g in select sp, min(nm) nm, min(em) em, count(*) n, sum(kg) kg, sum(v) v, sum(v_est) e, array_agg(id) gids
             from fi_catches where id = any(ids) and v_est < 300 group by sp order by sum(v_est) desc loop
    if g.e >= 60 then
      insert into fi_lots(user_id, at, nm, em, info, n, kg, v, e0) values (u, _now(), format('%s %s匹', g.nm, g.n), g.em, format('計%skg', round(g.kg, 2)), g.n, g.kg, g.v, g.e)
      returning id into lid;
      update fi_catches set status = 'lot', lot_id = lid where id = any(g.gids); nl := nl + 1;
    else
      small := small || g.gids; sv := sv + g.v; se := se + g.e; skg := skg + g.kg; sn := sn + g.n; snm := snm || format('%s %s', g.nm, g.n);
    end if;
  end loop;
  if sn > 0 then
    if se >= 60 then
      insert into fi_lots(user_id, at, nm, em, info, n, kg, v, e0) values (u, _now(), format('小物の盛り合わせ %s匹', sn), '🧺', array_to_string(snm, '・'), sn, skg, sv, se)
      returning id into lid;
      update fi_catches set status = 'lot', lot_id = lid where id = any(small); nl := nl + 1;
    else
      amt := greatest(1, round(sv * 0.8))::bigint;
      perform _give(u, amt);
      perform _log(u, 'fishing', 0, amt, jsonb_build_object('wholesale', true, 'n', sn));
      update fi_catches set status = 'wholesale' where id = any(small);
      return fi_state() || jsonb_build_object('lots_new', nl, 'wholesale', jsonb_build_object('n', sn, 'amt', amt));
    end if;
  end if;
  return fi_state() || jsonb_build_object('lots_new', nl);
end $$;

-- 大会に参加する（参加費。しめきりは終わりの5分前）
create or replace function public.fi_join() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); t fi_tourneys;
begin
  if not _beta_ok(u, 'fishing') then raise exception '準備中です。もうしばらくお待ちください'; end if;
  t := _fi_tourney(_kb_jday(_now()));
  if t.status <> 'open' or _now() >= t.end_at - interval '5 minutes' then raise exception 'きょうの大会の受付は終わりました'; end if;
  if exists (select 1 from fi_entries where day = t.day and user_id = u) then raise exception 'もう参加しています'; end if;
  perform _take(u, t.fee);
  perform _log(u, 'fishing', t.fee, 0, jsonb_build_object('tourney', t.day));
  insert into fi_entries(day, user_id, paid) values (t.day, u, t.fee);
  return fi_state();
end $$;

-- 競り市：出品された魚を品にする（値打ちは魚の本当の値打ち。目利きの見立てとコンピューターの値は、市場の品と同じつくり）
create or replace function public._au_lot_fi(l fi_lots, nb int) returns jsonb
language plpgsql volatile set search_path = public as $$
declare est jsonb := '[]'; hint jsonb := '[]'; rs jsonb := '[]'; i int; e numeric; step bigint; st0 bigint;
begin
  for i in 1..nb loop
    e := round(l.v * exp(_randn() * 0.16) / 10) * 10;
    est := est || to_jsonb(greatest(e, 10)); hint := hint || 'null'::jsonb;
    rs := rs || to_jsonb(round(greatest(e, 10) * (0.88 + random() * 0.14)));
  end loop;
  step := _au_step((l.e0 * 0.45)::bigint);
  st0 := greatest(round(l.e0 * 0.45 / step) * step, step);
  return jsonb_build_object('nm', l.nm, 'em', l.em, 'info', l.info, 'mk', 'fish', 'v', l.v, 'fake', false, 'start', st0, 'est', est, 'hint', hint, 'rs', rs,
                            'cid', l.id, 'by', (select nickname from profiles where id = l.user_id));
end $$;
-- 競りが始まるとき：出品された魚を品に入れる（席にいる人の品から先に、5品まで）
create or replace function public._au_consign(rid bigint, seats uuid[], st jsonb) returns jsonb
language plpgsql volatile set search_path = public as $$
declare l fi_lots; i int := 0; lot jsonb; seat int;
begin
  if coalesce(st->>'market', 'fish') not in ('fish', 'mix') then return st; end if;
  for l in select * from fi_lots where status = 'queued' order by (user_id = any(seats)) desc, at limit 5 for update skip locked loop
    seat := array_position(seats, l.user_id) - 1;
    lot := _au_lot_fi(l, (st->>'nb')::int) || jsonb_build_object('seller', seat);
    st := jsonb_set(st, array['lots', i::text], lot);
    update fi_lots set status = 'auction', room_id = rid where id = l.id;
    i := i + 1;
  end loop;
  return st;
end $$;
-- 競り市：出品された魚の落札（または流れ）
create or replace function public._fi_sold(cid bigint, w int, p bigint, rid bigint) returns void
language plpgsql volatile set search_path = public as $$
declare l fi_lots; fee bigint; nt bigint;
begin
  select * into l from fi_lots where id = cid for update;
  if not found or l.status <> 'auction' then return; end if;
  if w >= 0 and p is not null then
    fee := floor(p * 0.05); nt := p - fee;
    perform _give(l.user_id, nt);
    perform _log(l.user_id, 'fishing', 0, nt, jsonb_build_object('lot', cid, 'room', rid, 'price', p));
    update fi_lots set status = 'sold', price = p, net = nt, sold_at = _now() where id = cid;
    update fi_catches set status = 'sold' where lot_id = cid;
    perform _notice(l.user_id, format('【釣り】競り市で「%s」が %s X で売れました（手数料をのぞいて %s X）。', l.nm, _fmt(p), _fmt(nt)));
  else
    update fi_lots set status = 'queued', room_id = null where id = cid;
  end if;
end $$;

-- 毎分：大会・仲卸（pg_cron があるとき）
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-fish', '* * * * *', 'select public._fi_tick()');
  end if;
end $$;

-- =====================================================================
-- お金の動き（自分・会社）：すべて記録して消さない。画面ではさかのぼって全部見られる（CSV でも保存できる）
--   自分：所持金がかわるたびに money_log に1行（人のアカウントだけ）。同じ操作（トランザクション）の記録（tx_log）とまとめて見せる
--   会社：会社のお金は corp_ledger（_corp_move）に、すでに全部ある
-- =====================================================================
create table if not exists public.money_log (
  id      bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  delta   bigint not null,                       -- ＋入る −出る
  bal     bigint not null,                       -- かわったあとの所持金
  at      timestamptz not null default now(),
  txid    bigint not null default txid_current(),
  src     text                                   -- 呼ばれた操作（/rpc/…）。毎分の処理などは null
);
create index if not exists money_log_user on public.money_log(user_id, id desc);
alter table public.money_log enable row level security;
revoke all on public.money_log from anon, authenticated;
-- tx_log：同じ操作の所持金の動きとむすびつける（前からある行は null のまま）
alter table public.tx_log add column if not exists txid bigint;
alter table public.tx_log alter column txid set default txid_current();
create index if not exists tx_log_txid on public.tx_log(user_id, txid);

create or replace function public._money_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.ai is not null then return new; end if;   -- AIのアカウントは記録しない
  if tg_op = 'INSERT' then
    if coalesce(new.balance, 0) <> 0 then
      insert into money_log(user_id, delta, bal, at, src) values (new.id, new.balance, new.balance, _now(), nullif(current_setting('request.path', true), ''));
    end if;
  elsif new.balance is distinct from old.balance then
    insert into money_log(user_id, delta, bal, at, src) values (new.id, new.balance - old.balance, new.balance, _now(), nullif(current_setting('request.path', true), ''));
  end if;
  return new;
end $$;
drop trigger if exists money_trg on public.profiles;
create trigger money_trg after insert or update of balance on public.profiles for each row execute function public._money_trg();

-- 自分のお金の動き（新しい順。p_before・p_before_k：前のページの最後（時刻 ms と番号）より前。p_limit 件まで）
drop function if exists public.money_history(bigint, int);
create or replace function public.money_history(p_before bigint default null, p_before_k bigint default null, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); lim int := least(greatest(coalesce(p_limit, 100), 1), 500);
        bt timestamptz := case when p_before is null then 'infinity'::timestamptz else to_timestamp(p_before / 1000.0) end;
        bk bigint := coalesce(p_before_k, 9223372036854775807); items jsonb;
begin
  with grp as (
    select m.txid k, max(m.at) at, sum(m.delta) delta, (array_agg(m.bal order by m.id desc))[1] bal, min(m.src) src
      from money_log m where m.user_id = u group by m.txid
    having (date_trunc('milliseconds', max(m.at)), m.txid) < (date_trunc('milliseconds', bt), bk)
     order by max(m.at) desc, m.txid desc limit lim + 5),
  j as (
    select g.k, g.at, g.delta, g.bal, g.src,
           (select coalesce(jsonb_agg(jsonb_build_object('game', t.game, 'bet', t.bet, 'payout', t.payout, 'detail', t.detail) order by t.id), '[]'::jsonb)
              from tx_log t where t.user_id = u and t.txid = g.k) logs
      from grp g),
  old as (
    select t.id k, t.created_at at, t.payout - t.bet delta, t.balance_after bal, null::text src,
           jsonb_build_array(jsonb_build_object('game', t.game, 'bet', t.bet, 'payout', t.payout, 'detail', t.detail)) logs
      from tx_log t where t.user_id = u and t.txid is null and (date_trunc('milliseconds', t.created_at), t.id) < (date_trunc('milliseconds', bt), bk)
     order by t.created_at desc, t.id desc limit lim)
  select coalesce(jsonb_agg(jsonb_build_object('at_ms', _kb_ms(x.at), 'k', x.k, 'delta', x.delta, 'bal', x.bal, 'src', x.src, 'logs', x.logs) order by x.at desc, x.k desc), '[]'::jsonb)
    into items
    from (select * from (select * from j where delta <> 0 or jsonb_array_length(logs) > 0 union all select * from old) y order by date_trunc('milliseconds', y.at) desc, y.k desc limit lim) x;
  return jsonb_build_object('items', items, 'more', jsonb_array_length(items) >= lim, 'balance', _bal(u));
end $$;

-- 会社のお金の出入り（社長だけ。新しい順。p_before：この番号より前）
create or replace function public.corp_ledger_page(p_cid text, p_before bigint default null, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); c companies; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); items jsonb;
begin
  c := _my_corp(u, p_cid);
  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'kind', z.kind, 'amount', z.amount, 'memo', z.memo, 'bal', z.balance_after, 'at_ms', _kb_ms(z.created_at)) order by z.id desc), '[]'::jsonb)
    into items
    from (select * from corp_ledger where company_id = c.id and (p_before is null or id < p_before) order by id desc limit lim) z;
  return jsonb_build_object('items', items, 'more', jsonb_array_length(items) >= lim);
end $$;

-- 決まりの数字（画面にも出す）
create or replace function public._kb_own_c() returns jsonb
language sql immutable as $$
  select jsonb_build_object('start', 300, 'fixed', 800, 'upkeep', 20, 'fee', 5, 'max', 10, 'nsale', 8, 'step', 50,
                            'sale_dow', 6, 'sale_hour', 21, 'sale_hours', 24, 'snipe_min', 5, 'resale_days', 7)
$$;
-- 勝負服の色（_kb_new_horse と同じ）
create or replace function public._kb_colors() returns text[]
language sql immutable as $$
  select array['#C0283C','#1F4E9C','#1D7A4C','#E0A020','#6A2C91','#E86A17','#111111','#FFFFFF',
               '#E85D9A','#2BA6C9','#8B5A2B','#7A8B99','#F2D16B','#0F5E5A']
$$;
-- せりの時刻（その日の21:00）
create or replace function public._kb_sale_at(d date) returns timestamptz
language sql stable as $$
  select make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 21, 0, 0, 'Asia/Tokyo')
$$;
-- いまの「せりの日」（土曜）。土曜21:00より前なら先週の土曜
create or replace function public._kb_sale_day(ts timestamptz) returns date
language sql stable as $$
  select case when z.s = z.d and ts < _kb_sale_at(z.s) then z.s - 7 else z.s end
    from (select _kb_jday(ts) d, _kb_jday(ts) - ((extract(isodow from _kb_jday(ts))::int + 1) % 7) s) z
$$;
-- 持っている馬（引退した馬はのぞく）
create or replace function public._kb_owned_n(u uuid) returns int
language sql stable set search_path = public as $$
  select count(*)::int from keiba_horses where owner = u and not retired
$$;
-- せりで次につけられる値（はじめは開始の値。そのあとは5%か50 Xの大きいほう、10 X単位）
create or replace function public._kb_bid_min(s public.kb_sales) returns bigint
language sql immutable as $$
  select case when s.price is null then s.start_price
              else s.price + greatest(50, (ceil(s.price * 0.05 / 10.0) * 10)::bigint) end
$$;
-- 下見の見立て（本当の力・距離・芝ダートに、ゆらぎをつけて）
create or replace function public._kb_hint(hid int) returns jsonb
language plpgsql volatile set search_path = public as $$
declare h keiba_horses; s numeric; bd numeric; t numeric;
begin
  select * into h from keiba_horses where id = hid;
  s := h.ability + _kb_norm() * 4;
  bd := h.best_dist + _kb_norm() * 200;
  t := h.turf + _kb_norm() * 0.12;
  return jsonb_build_object(
    'eval', case when s >= 51 then 'A' when s >= 45 then 'B' when s >= 39 then 'C' else 'D' end,
    'dist', case when bd < 1500 then 'short' when bd < 1900 then 'mile' when bd < 2300 then 'mid' else 'long' end,
    'turf', case when t >= 0.62 then 'turf' when t <= 0.38 then 'dirt' else 'both' end);
end $$;
-- 馬主の勝負服（はじめて馬を持つときに、くじで決める）
create or replace function public._kb_owner_row(u uuid) returns public.kb_owners
language plpgsql volatile set search_path = public as $$
declare o kb_owners; c text[] := _kb_colors(); a text; b text;
begin
  select * into o from kb_owners where user_id = u;
  if found then return o; end if;
  a := c[1 + floor(random() * array_length(c, 1))::int];
  loop b := c[1 + floor(random() * array_length(c, 1))::int]; exit when b <> a; end loop;
  insert into kb_owners(user_id, silk1, silk2, silk_pat, since) values (u, a, b, floor(random() * 7)::int, _now())
  on conflict (user_id) do nothing;
  select * into o from kb_owners where user_id = u;
  return o;
end $$;
-- 馬を馬主のものにする（勝負服をその人のものに。登録・売り出しは消す）
create or replace function public._kb_give_horse(hid int, u uuid) returns void
language plpgsql volatile set search_path = public as $$
declare o kb_owners := _kb_owner_row(u);
begin
  update keiba_horses set owner = u, owned_at = _now(), barn = false, silk1 = o.silk1, silk2 = o.silk2, silk_pat = o.silk_pat where id = hid;
  delete from kb_regs where horse_id = hid;
  update kb_sales set status = 'cancel' where horse_id = hid and kind = 'resale' and status = 'open';
  perform _hc_ensure(hid);
  update kb_care set mode = 'auto', feed = 'normal' where horse_id = hid;
  perform _hc_apply(hid);
end $$;
-- 馬を手放す（ふつうの馬にもどる）
create or replace function public._kb_release(hid int) returns void
language plpgsql volatile set search_path = public as $$
begin
  update keiba_horses set owner = null, owned_at = null where id = hid;
  delete from kb_regs where horse_id = hid;
  update kb_sales set status = 'cancel' where horse_id = hid and kind = 'resale' and status = 'open';
  delete from kb_care where horse_id = hid;
  update keiba_horses set barn = false where id = hid;
end $$;
-- その日のレースに出られるか（クラス・年齢・前のレースから中1日）。年齢はその日の月で数える
create or replace function public._kb_can_run(h public.keiba_horses, p_cls int, p_cond text, d date) returns boolean
language sql stable as $$
  select not h.retired and not h.barn and (h.last_day is null or h.last_day < d - 1)
     and case when p_cls is not null then
               h.class = p_cls and case p_cond
                 when '2yo_new' then (extract(year from d)::int * 12 + extract(month from d)::int) - h.born = 2 and h.starts = 0
                 when '2yo'     then (extract(year from d)::int * 12 + extract(month from d)::int) - h.born = 2 and h.starts > 0
                 when '3yo'     then (extract(year from d)::int * 12 + extract(month from d)::int) - h.born = 3
                 else (extract(year from d)::int * 12 + extract(month from d)::int) - h.born >= 3 end
              else case p_cond
                 when '3yo' then (extract(year from d)::int * 12 + extract(month from d)::int) - h.born = 3 and h.class >= 2
                 else h.class = 4 and (extract(year from d)::int * 12 + extract(month from d)::int) - h.born >= 3 end
         end
$$;

-- 番組（その日のレースの時刻・条件・芝ダート・距離）を前もってつくる。_kb_make_day・_kb_make_noon・_kb_make_night と同じ並び
create or replace function public._kb_prog_day(d date) returns void
language plpgsql volatile set search_path = public as $$
declare
  dow int := extract(isodow from d)::int;
  wk int := (extract(day from d)::int - 1) / 7;
  finn text[] := array['月見草特別', '夜霧特別', '銀河特別', '星明かり特別', '真夜中特別', '夜想曲特別', '月光特別'];
  fins text[] := array['青空特別', '日だまり特別', '若葉特別', 'ひまわり特別', '昼下がり特別', '陽光特別', '白雲特別'];
  s int; k int; vid int; v keiba_venues; pt timestamptz; sf text; ds int; c int; cn text; nm text; nr keiba_names; knd text;
begin
  perform pg_advisory_xact_lock(4244);
  if exists (select 1 from kb_program p where p.day = d) then return; end if;
  -- ふだんのレース（16:30・17:30・18:30・19:30 から7Rずつ）
  for s in 0..3 loop
    vid := s + 1;
    select * into v from keiba_venues where id = vid;
    for k in 1..7 loop
      pt := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 16 + s, 30, 0, 'Asia/Tokyo') + (k - 1) * interval '8 minutes';
      sf := case when random() < 0.55 then '芝' else 'ダ' end;
      ds := case when sf = '芝' then v.turf_d[1 + floor(random() * array_length(v.turf_d, 1))::int]
                 else v.dirt_d[1 + floor(random() * array_length(v.dirt_d, 1))::int] end;
      case k
        when 1 then c := 0; cn := case when s % 2 = 0 then '2yo_new' else '2yo' end;
        when 2 then c := 0; cn := '3yo';
        when 3, 4 then c := 1; cn := '3up';
        when 5, 6 then c := 2; cn := '3up';
        else c := 3; cn := '3up';
      end case;
      nm := case cn when '2yo_new' then '2歳新馬' when '2yo' then '2歳未勝利' when '3yo' then '3歳未勝利' else '3歳以上' || c || '勝クラス' end;
      insert into kb_program(day, no, post, venue, rnum, name, grade, cls, cond, surface, dist, tier, handicap, nmin, nmax)
      values (d, s * 7 + k, pt, vid, k, nm, null, c, cn, sf, ds, 'normal', false, 8, 12);
    end loop;
  end loop;
  -- メインレース（20:30）
  knd := case dow when 7 then 'g1' when 6 then 'sat' else 'wd' end;
  select * into nr from keiba_names where kind = knd and idx = case when knd = 'wd' then dow else wk end;
  if not found then
    nr.name := 'オープン特別'; nr.grade := 'OP'; nr.surface := '芝'; nr.dist := 1800; nr.cond := '3up'; nr.handicap := false; nr.venue := 5;
  end if;
  insert into kb_program(day, no, post, venue, rnum, name, grade, cls, cond, surface, dist, tier, handicap, nmin, nmax)
  values (d, 29, make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 20, 30, 0, 'Asia/Tokyo'),
          coalesce(nr.venue, 5), 11, nr.name, nr.grade, null, nr.cond, nr.surface, nr.dist,
          case when nr.grade = 'G1' then 'g1' else 'graded' end, coalesce(nr.handicap, false),
          case nr.grade when 'G1' then 16 when 'G2' then 12 when 'G3' then 12 else 10 end,
          case nr.grade when 'G1' then 18 when 'G2' then 16 when 'G3' then 16 else 14 end);
  -- 深夜競馬（20:42 中京・21:42 京都）
  for s in 0..1 loop
    vid := case s when 0 then 1 else 2 end;
    select * into v from keiba_venues where id = vid;
    for k in 1..7 loop
      pt := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 20 + s, 42, 0, 'Asia/Tokyo') + (k - 1) * interval '8 minutes';
      sf := case when random() < 0.55 then '芝' else 'ダ' end;
      ds := case when sf = '芝' then v.turf_d[1 + floor(random() * array_length(v.turf_d, 1))::int]
                 else v.dirt_d[1 + floor(random() * array_length(v.dirt_d, 1))::int] end;
      case k
        when 1 then c := 0; cn := case when s = 0 then '2yo_new' else '2yo' end;
        when 2 then c := 0; cn := '3yo';
        when 3, 4 then c := 1; cn := '3up';
        when 5, 6 then c := 2; cn := '3up';
        else c := 3; cn := '3up';
      end case;
      nm := case when s = 1 and k = 7 then finn[dow]
                 else case cn when '2yo_new' then '2歳新馬' when '2yo' then '2歳未勝利' when '3yo' then '3歳未勝利' else '3歳以上' || c || '勝クラス' end end;
      insert into kb_program(day, no, post, venue, rnum, name, grade, cls, cond, surface, dist, tier, handicap, nmin, nmax)
      values (d, 30 + s * 7 + (k - 1), pt, vid, k, nm, null, c, cn, sf, ds, 'normal', false, 8, 12);
    end loop;
  end loop;
  -- 昼競馬（12:30〜 府中）
  vid := 3;
  select * into v from keiba_venues where id = vid;
  for k in 1..7 loop
    pt := make_timestamptz(extract(year from d)::int, extract(month from d)::int, extract(day from d)::int, 12, 30, 0, 'Asia/Tokyo') + (k - 1) * interval '10 minutes';
    sf := case when random() < 0.55 then '芝' else 'ダ' end;
    ds := case when sf = '芝' then v.turf_d[1 + floor(random() * array_length(v.turf_d, 1))::int]
               else v.dirt_d[1 + floor(random() * array_length(v.dirt_d, 1))::int] end;
    case k
      when 1 then c := 0; cn := '2yo_new';
      when 2 then c := 0; cn := '3yo';
      when 3, 4 then c := 1; cn := '3up';
      when 5, 6 then c := 2; cn := '3up';
      else c := 3; cn := '3up';
    end case;
    nm := case when k = 7 then fins[dow] else case cn when '2yo_new' then '2歳新馬' when '3yo' then '3歳未勝利' else '3歳以上' || c || '勝クラス' end end;
    insert into kb_program(day, no, post, venue, rnum, name, grade, cls, cond, surface, dist, tier, handicap, nmin, nmax)
    values (d, 43 + k, pt, vid, k, nm, null, c, cn, sf, ds, 'normal', false, 8, 12);
  end loop;
end $$;

-- 登録のあった馬を、そのレースに入れる（_kb_make_race から）。入れる馬（賞金の多い順・定員まで）を返す。入れなかった馬の馬主には知らせる
create or replace function public._kb_take_regs(d date, p_no int, p_cls int, p_cond text, nmax int, ptm text, vnm text, rn int, rname text) returns int[]
language plpgsql volatile set search_path = public as $$
declare g record; ids int[] := '{}';
begin
  for g in select r.horse_id, r.user_id, h.name, h.owner,
                  _hc_can_run(h, p_cls, p_cond, d) ok
             from kb_regs r join keiba_horses h on h.id = r.horse_id
            where r.day = d and r.no = p_no
            order by h.prize desc, h.wins desc, random() loop
    if not g.ok or g.owner is distinct from g.user_id then
      perform _notice(g.user_id, format('【馬主】「%s」は、%s %s %sR「%s」に出られなくなりました（条件が合わない・中1日あいていないなど）。登録は取り消しました。', g.name, ptm, vnm, rn, rname));
    elsif coalesce(array_length(ids, 1), 0) >= nmax then
      perform _notice(g.user_id, format('【馬主】「%s」は、%s %s %sR「%s」の登録が定員（%s頭）をこえたので出られませんでした（賞金の多い馬から出られます）。', g.name, ptm, vnm, rn, rname, nmax));
    else
      ids := ids || g.horse_id;
    end if;
  end loop;
  delete from kb_regs r where r.day = d and r.no = p_no;
  return ids;
end $$;

-- 馬主の時計（毎分）：競馬の時計・せり（はじめる・しめる）・定価と売り出しの期限・預託料・古い登録
create or replace function public._kb_own_tick() returns void
language plpgsql volatile set search_path = public as $$
begin
  begin perform _kb_tick(); exception when others then null; end;
  perform _kb_sales_tick();
  perform _hc_tick();
end $$;

-- せり：土曜21:00にはじめる・終わった馬をしめる・定価と売り出しの期限
create or replace function public._kb_sales_tick() returns void
language plpgsql volatile set search_path = public as $$
declare
  c jsonb := _kb_own_c(); sd date := _kb_sale_day(_now()); i int; hid int; s kb_sales; h keiba_horses; today date := _kb_jday(_now());
  g record;
begin
  perform pg_advisory_xact_lock(4245);
  -- 終わったせり
  for s in select * from kb_sales where kind = 'auction' and status = 'open' and ends_at <= _now() order by id for update loop
    select * into h from keiba_horses where id = s.horse_id;
    if s.event then   -- 運営が出品したせり
      if s.top is not null then
        perform _hx_sold(s, s.top, s.price, 'auction');
      else
        update kb_sales set status = 'unsold' where id = s.id;
        delete from kb_care where horse_id = s.horse_id;
        update keiba_horses set barn = false where id = s.horse_id and owner is null;
        if s.created_by is not null then
          perform _notice(s.created_by, format('【せり】「%s」は買い手がつきませんでした。ふつうの競走馬としてデビューします。', h.name));
        end if;
      end if;
    elsif s.top is not null then
      update kb_sales set status = 'sold', buyer = s.top, sold_price = s.price, sold_at = _now() where id = s.id;
      perform _log(s.top, 'owner', s.price, 0, jsonb_build_object('buy', s.horse_id, 'sale', s.id, 'kind', 'auction', 'title', format('「%s」を落札', h.name)));
      perform _kb_give_horse(s.horse_id, s.top);
      perform _notice(s.top, format('【せり】「%s」を %s X で落札しました。あなたの馬です（遊戯 → 馬主）。', h.name, _fmt(s.price)));
    else
      update kb_sales set status = 'unsold' where id = s.id;
      insert into kb_sales(horse_id, kind, week, opens_at, ends_at, start_price, price, info)
      values (s.horse_id, 'fixed', s.week, _now(), _kb_sale_at(s.week + 7), (c->>'fixed')::bigint, (c->>'fixed')::bigint, s.info);
    end if;
  end loop;
  -- 定価の期限（次のせりがはじまったら、ふつうの馬に）
  for s in select * from kb_sales where kind = 'fixed' and status = 'open' and ends_at <= _now() for update loop
    update kb_sales set status = 'expired' where id = s.id;
    update keiba_horses set barn = false where id = s.horse_id and owner is null;
  end loop;
  -- 馬主が売りに出した馬の期限
  for s in select * from kb_sales where kind = 'resale' and status = 'open' and ends_at <= _now() for update loop
    update kb_sales set status = 'expired' where id = s.id;
    select * into h from keiba_horses where id = s.horse_id;
    if s.seller is not null then
      perform _notice(s.seller, format('【馬主】売りに出していた「%s」は、%s日たっても買う人がいなかったので、売り出しをやめました。', h.name, c->>'resale_days'));
    end if;
  end loop;
  -- 毎週のせりは、やめました（せりは新東京競馬競市で、運営がイベントとして出品します）
  -- 古い出走登録（レースが行われなかった）
  for g in select r.horse_id, r.user_id, hh.name from kb_regs r join keiba_horses hh on hh.id = r.horse_id where r.day < today loop
    perform _notice(g.user_id, format('【馬主】「%s」の出走登録は、レースが行われなかったので取り消しました。', g.name));
    delete from kb_regs where horse_id = g.horse_id;
  end loop;
  delete from kb_program p where p.day < today - 1;
end $$;

-- 預託料（毎日6時。1頭20 X。その日の6時より前から持っている馬だけ。足りないときは、払える頭数だけ残して、新しく持った馬から手放す）
create or replace function public._kb_upkeep_tick() returns void
language plpgsql volatile set search_path = public as $$
begin
  perform _hc_daily();   -- 預託料は、エサ代になりました（_hc_daily）
end $$;

-- ---------------------------------------------------------------------
-- 画面から
-- ---------------------------------------------------------------------
create or replace function public._kb_own_open(u uuid) returns void
language plpgsql stable set search_path = public as $$
begin
  if not _beta_ok(u, 'owner') then raise exception '準備中です。もうしばらくお待ちください'; end if;
end $$;
-- 馬の見せかた（馬主の画面）
create or replace function public._kb_hjson(h public.keiba_horses) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', h.id, 'name', h.name, 'sex', h.sex, 'age', _kb_midx(_now()) - h.born, 'coat', h.coat, 'style', h.style,
                            'body', h.body, 'silk1', h.silk1, 'silk2', h.silk2, 'silk_pat', h.silk_pat, 'class', h.class,
                            'starts', h.starts, 'wins', h.wins, 'graded', h.graded, 'prize', h.prize, 'earned', h.earned, 'retired', h.retired)
$$;
create or replace function public.owner_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _me_g(); c jsonb := _kb_own_c(); o kb_owners; tm date; mine jsonb; prog jsonb; co companies := _hx_co();
begin
  perform _kb_own_open(u);
  perform _kb_sales_tick();
  tm := _kb_jday(_now()) + 1;
  select * into o from kb_owners where user_id = u;
  -- 自分の馬（育成のようすもいっしょに）
  select coalesce(jsonb_agg(_kb_hjson(h) || jsonb_build_object(
      'named', h.named, 'can_name', not h.named and h.starts = 0 and not h.retired,
      'care', _hc_json(h.id),
      'reg', (select jsonb_build_object('day', r.day, 'no', r.no, 'name', p.name, 'post_ms', _kb_ms(p.post), 'venue', v.name, 'rnum', p.rnum)
                from kb_regs r join kb_program p on p.day = r.day and p.no = r.no join keiba_venues v on v.id = p.venue where r.horse_id = h.id),
      'entry', (select jsonb_build_object('race', k.id, 'name', k.name, 'post_ms', _kb_ms(k.post), 'venue', v.name, 'rnum', k.rnum, 'uma', e.uma)
                  from keiba_entries e join keiba_races k on k.id = e.race_id join keiba_venues v on v.id = k.venue
                 where e.horse_id = h.id and not k.settled order by k.post limit 1),
      'listing', (select jsonb_build_object('sale', s.id, 'price', s.price, 'ends_ms', _kb_ms(s.ends_at)) from kb_sales s
                   where s.horse_id = h.id and s.kind = 'resale' and s.status = 'open' limit 1),
      'can', (select coalesce(jsonb_agg(p.no order by p.post), '[]'::jsonb) from kb_program p where p.day = tm and _hc_can_run(h, p.cls, p.cond, tm)),
      'last5', (select coalesce(jsonb_agg(jsonb_build_object('pos', x.pos, 'inc', x.incident) order by x.race_id desc), '[]'::jsonb)
                  from (select e2.race_id, e2.pos, e2.incident from keiba_entries e2 join keiba_races r2 on r2.id = e2.race_id
                         where e2.horse_id = h.id and r2.settled order by e2.race_id desc limit 5) x)
    ) order by h.retired, h.owned_at desc nulls last, h.id), '[]'::jsonb) into mine
    from keiba_horses h where h.owner = u;
  -- あしたの番組
  select coalesce(jsonb_agg(jsonb_build_object('no', p.no, 'post_ms', _kb_ms(p.post), 'venue', v.name, 'rnum', p.rnum, 'name', p.name,
                  'grade', p.grade, 'cls', p.cls, 'cond', p.cond, 'surface', p.surface, 'dist', p.dist, 'nmax', p.nmax,
                  'nreg', (select count(*) from kb_regs r where r.day = p.day and r.no = p.no)) order by p.post), '[]'::jsonb) into prog
    from kb_program p join keiba_venues v on v.id = p.venue where p.day = tm;
  return jsonb_build_object(
    'now_ms', _kb_ms(_now()), 'balance', _bal(u), 'c', c, 'hc', _hc_c(), 'guest', _is_guest(u),
    'silks', case when o.user_id is not null then jsonb_build_object('silk1', o.silk1, 'silk2', o.silk2, 'silk_pat', o.silk_pat) end,
    'colors', to_jsonb(_kb_colors()),
    -- せり（新東京競馬競市）
    'auction', jsonb_build_object('co', case when co.id is not null then jsonb_build_object('cid', co.cid, 'name', co.name, 'status', co.status) end,
                 'open', (select count(*) from kb_sales where event and status = 'open' and opens_at <= _now()),
                 'soon', (select count(*) from kb_sales where event and status = 'open' and opens_at > _now()),
                 'next_ms', (select _kb_ms(min(opens_at)) from kb_sales where event and status = 'open' and opens_at > _now()),
                 'end_ms', (select _kb_ms(min(ends_at)) from kb_sales where event and status = 'open' and opens_at <= _now()),
                 'holding', (select count(*) from kb_sales where event and status = 'open' and top = u)),
    'fixed', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'horse', _kb_hjson(h), 'info', s.info, 'price', s.price,
                       'ends_ms', _kb_ms(s.ends_at)) order by s.id), '[]'::jsonb)
                from kb_sales s join keiba_horses h on h.id = s.horse_id where s.kind = 'fixed' and s.status = 'open'),
    'resale', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'horse', _kb_hjson(h), 'price', s.price, 'ends_ms', _kb_ms(s.ends_at),
                        'seller', p.nickname, 'mine', s.seller = u) order by s.id desc), '[]'::jsonb)
                 from kb_sales s join keiba_horses h on h.id = s.horse_id left join profiles p on p.id = s.seller
                where s.kind = 'resale' and s.status = 'open'),
    'horses', mine, 'owned', _kb_owned_n(u),
    'tomorrow', tm, 'program', prog,
    'month', (select jsonb_build_object('prize', coalesce(sum(payout), 0), 'cost', coalesce(sum(bet), 0)) from tx_log
               where user_id = u and game = 'owner' and created_at >= _month_start(_month_of(_now()))));
end $$;

-- せりで値をつける（つけた値はあずかる。ほかの人に上回られたら返す。終わる5分前からは、値がつくたびに5分のびる）
create or replace function public.owner_bid(p_sale bigint, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); s kb_sales; mn bigint; nm text; c jsonb := _kb_own_c();
begin
  perform _kb_own_open(u);
  perform _kb_sales_tick();
  select * into s from kb_sales where id = p_sale for update;
  if not found or s.kind <> 'auction' or s.event then raise exception 'せりの馬が見つかりません'; end if;   -- 新東京競馬競市のせりは hx_bid から
  if s.status <> 'open' or _now() >= s.ends_at then raise exception 'この馬のせりは終わりました'; end if;
  if _now() < s.opens_at then raise exception 'せりは % からです', to_char(s.opens_at at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'); end if;
  if s.top = u then raise exception 'いちばん高い値をつけているのは、あなたです'; end if;
  mn := _kb_bid_min(s);
  if p_amount is null or p_amount < mn then raise exception '% X 以上の値をつけてください', _fmt(mn); end if;
  if p_amount > 100000000 then raise exception '値が大きすぎます'; end if;
  select name into nm from keiba_horses where id = s.horse_id;
  perform _take(u, p_amount);
  perform _log(u, 'owner_hold', p_amount, 0, jsonb_build_object('sale', s.id, 'horse', s.horse_id, 'title', format('「%s」に値をつけた', nm)));
  if s.top is not null then
    perform _give(s.top, s.price);
    perform _log(s.top, 'owner_back', 0, s.price, jsonb_build_object('sale', s.id, 'horse', s.horse_id, 'title', format('「%s」で上回られた', nm)));
    perform _notice(s.top, format('【せり】「%s」に、ほかの人がもっと高い値（%s X）をつけました。あずけていた %s X は返しました。', nm, _fmt(p_amount), _fmt(s.price)));
  end if;
  update kb_sales set price = p_amount, top = u, nbids = nbids + 1,
         ends_at = greatest(ends_at, _now() + make_interval(mins => (c->>'snipe_min')::int)) where id = s.id;
  insert into kb_bids(sale_id, user_id, amount, at) values (s.id, u, p_amount, _now());
  return owner_state();
end $$;

-- 定価の馬・馬主が売りに出した馬を買う
create or replace function public.owner_buy(p_sale bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); s kb_sales; h keiba_horses; c jsonb := _kb_own_c(); fee bigint;
begin
  perform _kb_own_open(u);
  if _is_guest(u) then raise exception 'ゲストは馬を買えません（本登録すると買えます）'; end if;
  perform _kb_sales_tick();
  select * into s from kb_sales where id = p_sale for update;
  if not found or s.kind not in ('fixed', 'resale') then raise exception '売り出し中の馬が見つかりません'; end if;
  if s.status <> 'open' or _now() >= s.ends_at then raise exception 'この馬はもう売れたか、売り出しが終わりました'; end if;
  if s.seller = u then raise exception '自分が売りに出した馬は買えません（やめるときは「売り出しをやめる」）'; end if;
  select * into h from keiba_horses where id = s.horse_id for update;
  if s.kind = 'resale' and (h.owner is distinct from s.seller or h.retired) then raise exception 'この馬はもう売り出されていません'; end if;
  perform _take(u, s.price);
  perform _log(u, 'owner', s.price, 0, jsonb_build_object('buy', h.id, 'sale', s.id, 'kind', s.kind, 'title', format('「%s」を買った', h.name)));
  update kb_sales set status = 'sold', buyer = u, sold_price = s.price, sold_at = _now() where id = s.id;
  if s.kind = 'resale' and s.seller is not null then
    fee := floor(s.price * (c->>'fee')::numeric / 100);
    perform _give(s.seller, s.price - fee);
    perform _log(s.seller, 'owner', 0, s.price - fee, jsonb_build_object('sell', h.id, 'sale', s.id, 'price', s.price, 'fee', fee, 'title', format('「%s」を売った', h.name)));
    perform _notice(s.seller, format('【馬主】「%s」が %s X で売れました（手数料 %s X をのぞいて %s X）。', h.name, _fmt(s.price), _fmt(fee), _fmt(s.price - fee)));
    perform _hx_paid(u, fee, 'horse', format('「%s」の売り出しの手数料', h.name));
  end if;
  perform _kb_give_horse(h.id, u);
  return owner_state();
end $$;

-- 勝負服（色2つと模様。持っている馬みんなに）
create or replace function public.owner_silks(p_silk1 text, p_silk2 text, p_pat int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); o kb_owners;
begin
  perform _kb_own_open(u);
  if not (p_silk1 = any(_kb_colors())) or not (p_silk2 = any(_kb_colors())) then raise exception '色をえらんでください'; end if;
  if p_silk1 = p_silk2 then raise exception '2つの色は、ちがう色にしてください'; end if;
  if p_pat is null or p_pat not between 0 and 6 then raise exception '模様をえらんでください'; end if;
  o := _kb_owner_row(u);
  update kb_owners set silk1 = p_silk1, silk2 = p_silk2, silk_pat = p_pat where user_id = u;
  update keiba_horses set silk1 = p_silk1, silk2 = p_silk2, silk_pat = p_pat where owner = u and not retired;
  return owner_state();
end $$;

-- 名前をつける（デビュー前に1回。カタカナ2〜9文字）
create or replace function public.owner_name(p_horse int, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses; n text := btrim(coalesce(p_name, ''));
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse for update;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  if h.retired then raise exception '引退した馬です'; end if;
  if h.named then raise exception '名前は1回だけつけられます'; end if;
  if h.starts > 0 then raise exception '名前はデビュー前（まだレースに出ていない馬）だけつけられます'; end if;
  if exists (select 1 from keiba_entries e join keiba_races k on k.id = e.race_id where e.horse_id = h.id and not k.settled) then
    raise exception 'デビューのレースが決まったので、もう名前はかえられません';
  end if;
  n := translate(n, 'ｰ', 'ー');
  if n !~ '^[ァ-ヴー]{2,9}$' then raise exception '名前はカタカナ2〜9文字にしてください'; end if;
  if n ~ '^ー' or n ~ 'ーー' then raise exception '名前のはじめや、つづけて「ー」は使えません'; end if;
  if n ~ '(シネ|コロス|ウンコ|チンコ|マンコ|セックス|キチガイ|ガイジ|ホモ|レイプ|ファック)' then raise exception 'その名前は使えません'; end if;
  if exists (select 1 from keiba_horses where name = n and id <> h.id) then raise exception 'その名前の馬はもういます'; end if;
  update keiba_horses set name = n, named = true where id = h.id;
  return owner_state();
end $$;

-- 出走登録（あしたのレース。1頭1つ。p_no が null なら登録をやめる）
create or replace function public.owner_reg(p_horse int, p_no int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses; p kb_program; tm date := _kb_jday(_now()) + 1;
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  if p_no is null then delete from kb_regs where horse_id = h.id; return owner_state(); end if;
  if h.retired then raise exception '引退した馬です'; end if;
  perform _hc_ensure(h.id);
  select * into p from kb_program pp where pp.day = tm and pp.no = p_no;
  if not found then raise exception 'あしたのレースが見つかりません（番組は毎日0時ごろに出ます）'; end if;
  if exists (select 1 from keiba_races k where k.day = tm and k.no = p_no) then raise exception 'このレースの登録は締め切りました'; end if;
  if not _hc_can_run(h, p.cls, p.cond, tm) then
    raise exception 'この馬は、このレースには出られません（クラス・年齢・前のレースから中1日・病気・休養など）';
  end if;
  insert into kb_regs(horse_id, day, no, user_id, at) values (h.id, tm, p_no, u, _now())
  on conflict (horse_id) do update set day = excluded.day, no = excluded.no, user_id = excluded.user_id, at = excluded.at;
  return owner_state();
end $$;

-- 売りに出す（p_price が null なら売り出しをやめる）
create or replace function public.owner_sell(p_horse int, p_price bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses; c jsonb := _kb_own_c();
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse for update;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  if p_price is null then
    update kb_sales set status = 'cancel' where horse_id = h.id and kind = 'resale' and status = 'open';
    return owner_state();
  end if;
  if h.retired then raise exception '引退した馬は売れません'; end if;
  if p_price < 100 or p_price > 100000000 then raise exception '売り値は 100 X から 100,000,000 X までです'; end if;
  if exists (select 1 from kb_sales where horse_id = h.id and kind = 'resale' and status = 'open') then raise exception 'もう売りに出しています'; end if;
  insert into kb_sales(horse_id, kind, seller, opens_at, ends_at, start_price, price)
  values (h.id, 'resale', u, _now(), _now() + make_interval(days => (c->>'resale_days')::int), p_price, p_price);
  return owner_state();
end $$;

-- 引退（出走が決まっているレースがあるあいだは、できない）
create or replace function public.owner_retire(p_horse int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses;
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse for update;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  if h.retired then raise exception 'もう引退しています'; end if;
  if exists (select 1 from keiba_entries e join keiba_races k on k.id = e.race_id where e.horse_id = h.id and not k.settled) then
    raise exception '出走が決まっているレースが終わってから引退させてください';
  end if;
  update keiba_horses set retired = true where id = h.id;
  delete from kb_regs where horse_id = h.id;
  update kb_sales set status = 'cancel' where horse_id = h.id and kind = 'resale' and status = 'open';
  return owner_state();
end $$;

-- 毎分：馬主の時計（pg_cron があるとき）
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.schedule('ailinax-owner', '* * * * *', 'select public._kb_own_tick()');
  end if;
end $$;

-- =====================================================================
-- ゲームタスク・ゲームランク・カジノランク
--   タスク：毎日（日本時間の0時に新しく）、人ごとに4つ。1つクリアで 400 X、4つともクリアで さらに 400 X（1日最大 2,000 X）
--           ゲストは 1つ 100 X・全部で さらに 100 X（最大 500 X）。クリアしたときに国庫から自動で入る（所得）。国庫が足りないときは入らない
--   ゲームランク：遊ぶたびに経験値（賭けた額が大きいほど少し多め・勝つとおまけ・タスクのクリアでも）。月のはじめにレベル1から
--                 レベルごとに称号。一度とった称号は残る（名前の横には、今月のレベルの称号）
--   カジノランク：カジノ（スロット・ブラックジャック・ルーレット・ハイ＆ロー）と競馬・競艇・競輪。10 X 以上の1回で1点、勝つと さらに2点
--                 最後に遊んでから7日すぎると、1日5%ずつ下がる
--   数えるもと：遊んだ記録（tx_log）・馬券や券を買ったとき・対戦が終わったとき・魚をつったとき。ゲームの処理は止めない（まちがいがあっても何もしない）
-- =====================================================================
create table if not exists public.gt_days (
  user_id  uuid not null references public.profiles(id) on delete cascade,
  day      date not null,                        -- 日本時間の日付
  kinds    text[] not null default '{}',         -- その日に遊んだゲームの種類（「○種類のゲームで遊ぶ」）
  bets     bigint not null default 0,            -- その日に賭けた合計（カジノ・公営競技）
  guest    boolean not null default false,       -- ゲストの日（ごほうびが少ない）
  bonus    int not null default 0,               -- 全部クリアのごほうび（払った額）
  bonus_at timestamptz,
  primary key (user_id, day)
);
create table if not exists public.gt_tasks (
  user_id uuid not null,
  day     date not null,
  no      smallint not null,                     -- 1〜4
  kind    text not null,
  goal    int not null,                          -- めざす数（「賭ける」は X）
  prog    int not null default 0,
  reward  int not null,
  done_at timestamptz,                           -- クリアした時刻
  paid    int not null default 0,                -- 払った額（国庫が足りないと 0）
  primary key (user_id, day, no),
  foreign key (user_id, day) references public.gt_days(user_id, day) on delete cascade
);
create table if not exists public.gt_xp (            -- ゲームランク（月ごと）
  user_id uuid not null references public.profiles(id) on delete cascade,
  month   int not null,
  xp      bigint not null default 0,
  plays   int not null default 0,
  wins    int not null default 0,
  primary key (user_id, month)
);
create index if not exists gt_xp_month_idx on public.gt_xp(month, xp desc);
create table if not exists public.gt_titles (        -- とった称号（ずっと残る）
  user_id uuid not null references public.profiles(id) on delete cascade,
  lv      int not null,
  month   int not null,                          -- はじめてとった月
  at      timestamptz not null default now(),
  primary key (user_id, lv)
);
create table if not exists public.gt_casino (        -- カジノランク
  user_id uuid primary key references public.profiles(id) on delete cascade,
  pts     numeric not null default 0,            -- ポイント（下がる分は、つぎに遊んだときにまとめて引く）
  plays   bigint not null default 0,
  wins    bigint not null default 0,
  last_at timestamptz,                           -- 最後にカジノ・公営競技で遊んだ時刻
  best    numeric not null default 0             -- いちばん高かったポイント
);
alter table public.gt_days    enable row level security;
alter table public.gt_tasks   enable row level security;
alter table public.gt_xp      enable row level security;
alter table public.gt_titles  enable row level security;
alter table public.gt_casino  enable row level security;
alter table public.treasury add column if not exists task_total bigint not null default 0;   -- タスクのごほうび（累計）

create or replace function public._gt_today() returns date
language sql stable set search_path = public as $$ select (_now() at time zone 'Asia/Tokyo')::date $$;

-- タスクの種類：kind・文（{n} に数）・めざす数の候補・グループ（同じ日に同じグループは出さない）・出やすさ
create or replace function public._gt_kinds() returns table(kind text, label text, goals int[], grp text, w int)
language sql immutable as $$
  select * from (values
    ('slot',     'スロットを{n}回まわす',               array[10, 20, 30],      'slot',  3),
    ('slot_win', 'スロットで{n}回当てる',               array[2, 3, 5],         'slot',  2),
    ('bj',       'ブラックジャックを{n}回あそぶ',       array[3, 5, 8],         'bj',    3),
    ('bj_win',   'ブラックジャックで{n}回勝つ',         array[1, 2, 3],         'bj',    2),
    ('rou',      'ルーレットで{n}回賭ける',             array[5, 10],           'rou',   3),
    ('rou_win',  'ルーレットで{n}回当てる',             array[1, 2, 3],         'rou',   2),
    ('hilo',     'ハイ＆ローを{n}回あそぶ',             array[3, 5],            'hilo',  3),
    ('hilo_win', 'ハイ＆ローで{n}回勝つ',               array[1, 2],            'hilo',  2),
    ('race',     '競馬の馬券を{n}枚買う',               array[1, 3, 5],         'race',  3),
    ('race_hit', '競馬で{n}回当てる',                   array[1, 2],            'race',  1),
    ('pr',       '競艇か競輪の券を{n}枚買う',           array[1, 3],            'pr',    2),
    ('room',     '対戦ゲームを{n}回あそぶ（CPUとでも・1分以上）', array[1, 2],    'room',  2),
    ('fish',     '釣りで{n}匹つる',                     array[3, 5],            'fish',  2),
    ('bets',     'カジノと公営競技で合計{n} X 賭ける',  array[300, 500, 1000],  'bets',  2),
    ('kinds',    '{n}種類のゲームで遊ぶ',               array[3, 4],            'kinds', 2)
  ) t(kind, label, goals, grp, w) $$;
-- その人に出せるもの（まだ公開していないゲームは出さない）
create or replace function public._gt_pool(u uuid) returns table(kind text, label text, goals int[], grp text, w int)
language sql stable set search_path = public as $$
  select t.* from _gt_kinds() t
   where (t.kind <> 'pr' or _beta_ok(u, 'boat') or _beta_ok(u, 'bike'))
     and (t.kind <> 'fish' or _beta_ok(u, 'fishing')) $$;
create or replace function public._gt_label(k text, n int) returns text
language sql stable set search_path = public as $$
  select replace(coalesce((select t.label from _gt_kinds() t where t.kind = k), k), '{n}', _fmt(n)) $$;

-- その日のタスクを用意する（まだなければ。4つ。グループがかぶらないように、出やすさの重みつきでえらぶ）。AIのアカウントは null
create or replace function public._gt_ensure(u uuid) returns date
language plpgsql set search_path = public as $$
declare d date := _gt_today(); g boolean; r record; used text[] := '{}'; n int := 0; per int;
begin
  if exists (select 1 from gt_days where user_id = u and day = d) then return d; end if;
  if not exists (select 1 from profiles where id = u and ai is null) then return null; end if;
  g := _is_guest(u);
  insert into gt_days(user_id, day, guest) values (u, d, g) on conflict do nothing;
  if not found then return d; end if;          -- ほかで同時に作った
  per := case when g then 100 else 400 end;
  for r in select p.* from _gt_pool(u) p order by -ln(1 - random()) / p.w loop
    continue when r.grp = any(used);
    n := n + 1; used := used || r.grp;
    insert into gt_tasks(user_id, day, no, kind, goal, reward)
    values (u, d, n, r.kind, r.goals[1 + floor(random() * cardinality(r.goals))::int], per);
    exit when n >= 4;
  end loop;
  delete from gt_days where user_id = u and day < d - 14;    -- 2週間より前の日は消す
  return d;
end $$;

-- 経験値：賭けた額から（10 X で3・100 X で10・400 X で20・1,600 X 以上で40）
create or replace function public._gt_xpb(bet bigint) returns int
language sql immutable as $$ select least(40, greatest(1, round(sqrt(greatest(coalesce(bet, 0), 0)::numeric))::int)) $$;
-- レベル L になるのに要る経験値：50·L·(L−1)（L1 は 0、L2 は 100、L3 は 300、L10 は 4,500…）
create or replace function public._gt_need(lv int) returns bigint
language sql immutable as $$ select (50::bigint * lv * (lv - 1)) $$;
create or replace function public._gt_lv(xp bigint) returns int
language plpgsql immutable as $$
declare l int := greatest(1, floor((1 + sqrt(1 + 0.08 * greatest(coalesce(xp, 0), 0)::numeric)) / 2)::int);
begin
  while _gt_need(l + 1) <= coalesce(xp, 0) loop l := l + 1; end loop;
  while l > 1 and _gt_need(l) > coalesce(xp, 0) loop l := l - 1; end loop;
  return l;
end $$;
-- 称号（レベル・名前）
create or replace function public._gt_titles() returns table(lv int, name text)
language sql immutable as $$
  select * from (values (3, '見習い'), (5, '常連さん'), (10, '腕利き'), (15, '勝負師'), (20, '目利き'), (25, '千両役者'),
                        (30, '風の芽の名手'), (40, '豪傑'), (50, '伝説の勝負師'), (70, '風の芽の主'), (100, '天下無双')) t(lv, name) $$;
create or replace function public._gt_title(lv int) returns text
language sql immutable as $$ select t.name from _gt_titles() t where t.lv <= $1 order by t.lv desc limit 1 $$;
-- カジノランクの段
create or replace function public._gt_tiers() returns table(tier int, name text, pts int)
language sql immutable as $$
  select * from (values (0, 'ビギナー', 0), (1, 'ブロンズ', 30), (2, 'シルバー', 150), (3, 'ゴールド', 500), (4, 'プラチナ', 1500),
                        (5, 'ダイヤモンド', 4000), (6, 'マスター', 10000), (7, 'レジェンド', 25000)) t(tier, name, pts) $$;
create or replace function public._gt_tier(p numeric) returns int
language sql immutable as $$ select coalesce(max(t.tier), 0) from _gt_tiers() t where t.pts <= floor(coalesce($1, 0)) $$;
create or replace function public._gt_tname(t int) returns text
language sql immutable as $$ select z.name from _gt_tiers() z where z.tier = $1 $$;
-- いまのポイント（最後に遊んでから7日すぎると、1日5%ずつ下がる）
create or replace function public._gt_cpts(p numeric, last_at timestamptz) returns numeric
language sql stable set search_path = public as $$
  select case when last_at is null or coalesce(p, 0) <= 0 then greatest(coalesce(p, 0), 0)
              else p * power(0.95::numeric, greatest(0, floor(extract(epoch from (_now() - last_at)) / 86400)::int - 7)) end $$;
-- 名前の横のしるし用（今月の称号・カジノランクの段）
create or replace function public._gt_badge(u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'ttl', _gt_title(_gt_lv(coalesce((select x.xp from gt_xp x where x.user_id = u and x.month = _month_of(_now())), 0))),
    'cr', _gt_tier(coalesce((select _gt_cpts(c.pts, c.last_at) from gt_casino c where c.user_id = u), 0))) $$;

-- 経験値を足す（レベルが上がって新しい称号に届いたら、とった称号に入れて知らせる）
create or replace function public._gt_add_xp(u uuid, n int, play boolean, win boolean) returns void
language plpgsql set search_path = public as $$
declare m int := _month_of(_now()); x bigint; t record; lv1 int;
begin
  insert into gt_xp(user_id, month, xp, plays, wins)
  values (u, m, greatest(n, 0), case when play then 1 else 0 end, case when win then 1 else 0 end)
  on conflict (user_id, month) do update set xp = gt_xp.xp + excluded.xp, plays = gt_xp.plays + excluded.plays, wins = gt_xp.wins + excluded.wins
  returning xp into x;
  lv1 := _gt_lv(x);
  if lv1 > _gt_lv(x - greatest(n, 0)) then
    for t in select z.* from _gt_titles() z where z.lv <= lv1 and z.lv > _gt_lv(x - greatest(n, 0)) order by z.lv loop
      insert into gt_titles(user_id, lv, month, at) values (u, t.lv, m, _now()) on conflict do nothing;
      if found then perform _notice(u, format('【ゲームランク】レベル%sになって、称号「%s」をとりました！', t.lv, t.name)); end if;
    end loop;
  end if;
end $$;

-- カジノランク：1回（10 X 以上）で1点、勝つと さらに2点。上の段に上がったら知らせる
create or replace function public._gt_casino(u uuid, win boolean) returns void
language plpgsql set search_path = public as $$
declare c gt_casino; p numeric; t0 int; t1 int;
begin
  insert into gt_casino(user_id) values (u) on conflict do nothing;
  select * into c from gt_casino where user_id = u for update;
  p := _gt_cpts(c.pts, c.last_at); t0 := _gt_tier(p);
  p := p + 1 + case when win then 2 else 0 end; t1 := _gt_tier(p);
  update gt_casino set pts = p, plays = plays + 1, wins = wins + case when win then 1 else 0 end, last_at = _now(), best = greatest(best, p)
   where user_id = u;
  if t1 > t0 then perform _notice(u, format('【カジノランク】カジノランクが「%s」に上がりました！', _gt_tname(t1))); end if;
end $$;

-- 国庫からごほうびを払う（足りないときは払わない）。払った額を返す。why はタスクの文（全部クリアのときは null）
create or replace function public._gt_pay(u uuid, amt int, why text) returns int
language plpgsql set search_path = public as $$
declare tb bigint;
begin
  select balance into tb from treasury where id = 1 for update;
  if coalesce(tb, 0) < amt then
    perform _notice(u, case when why is null then format('【タスク】今日のタスクを全部クリアしましたが、国庫が足りないため、ごほうび %s X は入りませんでした', _fmt(amt))
                            else format('【タスク】「%s」をクリアしましたが、国庫が足りないため、ごほうび %s X は入りませんでした', why, _fmt(amt)) end);
    return 0;
  end if;
  update treasury set balance = balance - amt, task_total = task_total + amt where id = 1;
  perform _give(u, amt);
  perform _log(u, 'task', 0, amt, jsonb_build_object('task', coalesce(why, 'all')));
  perform _notice(u, case when why is null then format('【タスク】今日のタスクを全部クリア！ ごほうび %s X が入りました', _fmt(amt))
                          else format('【タスク】「%s」をクリア！ %s X が入りました', why, _fmt(amt)) end);
  return amt;
end $$;

-- クリアしたタスクと、全部クリアのごほうびを払う
create or replace function public._gt_settle(u uuid, d date) returns void
language plpgsql set search_path = public as $$
declare t record; gd gt_days; p int;
begin
  for t in select * from gt_tasks where user_id = u and day = d and done_at is null and prog >= goal order by no for update loop
    p := _gt_pay(u, t.reward, _gt_label(t.kind, t.goal));
    update gt_tasks set done_at = _now(), paid = p where user_id = u and day = d and no = t.no;
    perform _gt_add_xp(u, 50, false, false);
  end loop;
  select * into gd from gt_days where user_id = u and day = d for update;
  if found and gd.bonus_at is null and exists (select 1 from gt_tasks where user_id = u and day = d)
     and not exists (select 1 from gt_tasks where user_id = u and day = d and done_at is null) then
    p := _gt_pay(u, case when gd.guest then 100 else 400 end, null);
    update gt_days set bonus_at = _now(), bonus = p where user_id = u and day = d;
    perform _gt_add_xp(u, 100, false, false);
  end if;
end $$;

-- 遊んだ1回ごと：経験値・カジノランク・タスク
--   k：slot / blackjack / roulette / hilo（1回）・race / boat / keirin（券の結果）・kb_buy / pr_buy（券を買った）・room（対戦が終わった）・fish（つった）・lottery（ジャンボを買った）
create or replace function public._gt_event0(u uuid, k text, bet bigint, pay bigint, refund boolean) returns void
language plpgsql set search_path = public as $$
declare d date; kd text;
        cas boolean := k in ('slot', 'blackjack', 'roulette', 'hilo');
        win boolean := coalesce(pay, 0) > coalesce(bet, 0) and not coalesce(refund, false);
        hit boolean := coalesce(pay, 0) > 0 and not coalesce(refund, false);
        xp int;
begin
  if u is null or not exists (select 1 from profiles where id = u and ai is null) then return; end if;
  -- ゲームランクの経験値
  xp := case when cas then _gt_xpb(bet) + case when win then 5 else 0 end
             when k in ('kb_buy', 'pr_buy', 'lottery') then _gt_xpb(bet)
             when k in ('race', 'boat', 'keirin') then case when hit then 5 else 0 end
             when k = 'room' then 30 + case when win then 20 else 0 end
             when k = 'fish' then 5 else 0 end;
  if xp > 0 or cas or k in ('kb_buy', 'pr_buy', 'room') then
    perform _gt_add_xp(u, xp, cas or k in ('kb_buy', 'pr_buy', 'room'),
                       (cas and win) or (k in ('race', 'boat', 'keirin') and hit) or (k = 'room' and win));
  end if;
  -- カジノランク（10 X 以上の1回。競馬・競艇・競輪は券の結果で。返った券は数えない）
  if (cas or k in ('race', 'boat', 'keirin')) and coalesce(bet, 0) >= 10 and not coalesce(refund, false) then
    perform _gt_casino(u, win);
  end if;
  -- タスク
  d := _gt_ensure(u);
  if d is null then return; end if;
  kd := case k when 'slot' then 'slot' when 'blackjack' then 'bj' when 'roulette' then 'rou' when 'hilo' then 'hilo'
               when 'kb_buy' then 'race' when 'pr_buy' then 'pr' when 'room' then 'room' when 'fish' then 'fish' end;
  if kd is not null then
    update gt_days set kinds = kinds || kd where user_id = u and day = d and not (kd = any(kinds));
  end if;
  if cas or k in ('kb_buy', 'pr_buy') then
    update gt_days set bets = bets + greatest(coalesce(bet, 0), 0) where user_id = u and day = d;
  end if;
  update gt_tasks t set prog = case t.kind
           when 'bets' then least(t.goal::bigint, (select z.bets from gt_days z where z.user_id = u and z.day = d))::int
           when 'kinds' then least(t.goal, (select cardinality(z.kinds) from gt_days z where z.user_id = u and z.day = d))
           else least(t.goal, t.prog + 1) end
   where t.user_id = u and t.day = d and t.done_at is null
     and (   (t.kind = 'slot' and k = 'slot')           or (t.kind = 'slot_win' and k = 'slot' and hit)
          or (t.kind = 'bj' and k = 'blackjack')        or (t.kind = 'bj_win' and k = 'blackjack' and win)
          or (t.kind = 'rou' and k = 'roulette')        or (t.kind = 'rou_win' and k = 'roulette' and hit)
          or (t.kind = 'hilo' and k = 'hilo')           or (t.kind = 'hilo_win' and k = 'hilo' and win)
          or (t.kind = 'race' and k = 'kb_buy')         or (t.kind = 'race_hit' and k = 'race' and hit)
          or (t.kind = 'pr' and k = 'pr_buy')           or (t.kind = 'room' and k = 'room')
          or (t.kind = 'fish' and k = 'fish')
          or (t.kind = 'bets' and (cas or k in ('kb_buy', 'pr_buy')))
          or (t.kind = 'kinds' and kd is not null));
  perform _gt_settle(u, d);
end $$;
-- ゲームの処理を止めないように（まちがいがあっても、そのぶんだけなかったことにする）
create or replace function public._gt_event(u uuid, k text, bet bigint, pay bigint, refund boolean) returns void
language plpgsql set search_path = public as $$
begin
  perform _gt_event0(u, k, bet, pay, refund);
exception when others then
  raise warning 'gt_event %: %', k, sqlerrm;
end $$;

-- 記録（tx_log）から：カジノ・競馬・競艇・競輪の結果、ジャンボを買った
create or replace function public._gt_tx_trg() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.game in ('slot', 'blackjack', 'roulette', 'hilo', 'race', 'boat', 'keirin') then
    perform _gt_event(new.user_id, new.game, new.bet, new.payout, coalesce(new.detail->>'refund', '') = 'true');
  elsif new.game = 'lottery' and new.bet > 0 then
    perform _gt_event(new.user_id, 'lottery', new.bet, 0, false);
  end if;
  return null;
end $$;
drop trigger if exists gt_tx on public.tx_log;
create trigger gt_tx after insert on public.tx_log for each row execute function public._gt_tx_trg();
-- 馬券を買った・競艇や競輪の券を買った・魚をつった
create or replace function public._gt_buy_trg() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_table_name = 'keiba_tickets' then perform _gt_event(new.user_id, 'kb_buy', new.amount, 0, false);
  elsif tg_table_name = 'pr_tickets' then perform _gt_event(new.user_id, 'pr_buy', new.amount, 0, false);
  elsif tg_table_name = 'fi_catches' then perform _gt_event(new.user_id, 'fish', 0, 0, false);
  end if;
  return null;
end $$;
drop trigger if exists gt_kb on public.keiba_tickets;
create trigger gt_kb after insert on public.keiba_tickets for each row execute function public._gt_buy_trg();
drop trigger if exists gt_pr on public.pr_tickets;
create trigger gt_pr after insert on public.pr_tickets for each row execute function public._gt_buy_trg();
drop trigger if exists gt_fi on public.fi_catches;
create trigger gt_fi after insert on public.fi_catches for each row execute function public._gt_buy_trg();
-- 対戦が終わった（1分以上つづいた対戦。席にいた人それぞれ。勝った席は勝ち）
create or replace function public._gt_room_trg() returns trigger
language plpgsql set search_path = public as $$
declare i int;
begin
  if new.status = 'finished' and old.status is distinct from 'finished' and new.started_at is not null
     and coalesce(new.finished_at, _now()) - new.started_at >= interval '60 seconds' then
    for i in 1 .. coalesce(cardinality(new.seats), 0) loop
      if new.seats[i] is not null then
        perform _gt_event(new.seats[i], 'room', 0, case when new.winner = i - 1 then 1 else 0 end, false);
      end if;
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists gt_room on public.game_rooms;
create trigger gt_room after update of status on public.game_rooms for each row execute function public._gt_room_trg();

-- 今日のタスクの残り（メニューの印に）
create or replace function public._gt_brief(u uuid) returns jsonb
language plpgsql set search_path = public as $$
declare d date := _gt_ensure(u);
begin
  if d is null then return null; end if;
  return (select jsonb_build_object('left', count(*) filter (where t.done_at is null), 'n', count(*)) from gt_tasks t where t.user_id = u and t.day = d);
end $$;

-- 番付（今月のゲームランク・いまのカジノランク。ゲストとAIは出さない）
create or replace function public._gt_board(u uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'lv', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'me', p.id = u,
                'lv', _gt_lv(z.xp), 'title', _gt_title(_gt_lv(z.xp))) order by z.xp desc, p.nickname), '[]'::jsonb)
             from (select x.* from gt_xp x where x.month = _month_of(_now()) and x.xp > 0
                      and not _is_guest(x.user_id) order by x.xp desc limit 10) z join profiles p on p.id = z.user_id and p.ai is null),
    'cr', (select coalesce(jsonb_agg(jsonb_build_object('nickname', p.nickname, 'uid', p.account_no, 'badge', _badge(p.id), 'me', p.id = u,
                'pts', floor(z.e)::bigint, 'tier', _gt_tier(z.e), 'name', _gt_tname(_gt_tier(z.e))) order by z.e desc, p.nickname), '[]'::jsonb)
             from (select c.user_id, _gt_cpts(c.pts, c.last_at) e from gt_casino c where not _is_guest(c.user_id)
                    order by 2 desc limit 10) z join profiles p on p.id = z.user_id and p.ai is null where z.e >= 1)) $$;

-- 遊戯の「タスク」の画面：今日のタスク・ゲームランク（今月）・とった称号・カジノランク・番付
create or replace function public.game_tasks() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); d date; gd gt_days; m int := _month_of(_now()); x gt_xp; mylv int; c gt_casino; p numeric; t int; idle int;
begin
  d := _gt_ensure(u);
  select * into gd from gt_days where user_id = u and day = d;
  select * into x from gt_xp where user_id = u and month = m;
  mylv := _gt_lv(coalesce(x.xp, 0));
  select * into c from gt_casino where user_id = u;
  p := _gt_cpts(c.pts, c.last_at); t := _gt_tier(p);
  idle := case when c.last_at is null then null else floor(extract(epoch from (_now() - c.last_at)) / 86400)::int end;
  return jsonb_build_object(
    'day', _dlabel(_now()), 'guest', coalesce(gd.guest, _is_guest(u)),
    'per', case when coalesce(gd.guest, _is_guest(u)) then 100 else 400 end,
    'max', case when coalesce(gd.guest, _is_guest(u)) then 500 else 2000 end,
    'tasks', (select coalesce(jsonb_agg(jsonb_build_object('no', z.no, 'kind', z.kind, 'label', _gt_label(z.kind, z.goal), 'goal', z.goal, 'prog', z.prog,
                'reward', z.reward, 'done', z.done_at is not null, 'paid', z.paid) order by z.no), '[]'::jsonb)
                from gt_tasks z where z.user_id = u and z.day = d),
    'bonus', jsonb_build_object('reward', case when coalesce(gd.guest, _is_guest(u)) then 100 else 400 end, 'done', gd.bonus_at is not null, 'paid', coalesce(gd.bonus, 0)),
    'got', coalesce((select sum(z.paid) from gt_tasks z where z.user_id = u and z.day = d), 0) + coalesce(gd.bonus, 0),
    'level', jsonb_build_object('month', m % 100, 'ym', format('%s年%s月', m / 100, m % 100), 'lv', mylv, 'xp', coalesce(x.xp, 0), 'base', _gt_need(mylv), 'next', _gt_need(mylv + 1),
               'plays', coalesce(x.plays, 0), 'wins', coalesce(x.wins, 0), 'title', _gt_title(mylv),
               'next_title', (select jsonb_build_object('lv', z.lv, 'name', z.name) from _gt_titles() z where z.lv > mylv order by z.lv limit 1)),
    'titles', (select jsonb_agg(jsonb_build_object('lv', z.lv, 'name', z.name, 'got', g.lv is not null,
                 'month', case when g.lv is not null then format('%s年%s月', g.month / 100, g.month % 100) end) order by z.lv)
                 from _gt_titles() z left join gt_titles g on g.user_id = u and g.lv = z.lv),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('month', format('%s年%s月', z.month / 100, z.month % 100), 'lv', _gt_lv(z.xp),
                  'title', _gt_title(_gt_lv(z.xp))) order by z.month desc), '[]'::jsonb)
                  from (select * from gt_xp where user_id = u and month < m order by month desc limit 6) z),
    'casino', jsonb_build_object('tier', t, 'name', _gt_tname(t), 'pts', floor(p)::bigint,
                'base', (select z.pts from _gt_tiers() z where z.tier = t),
                'next', (select jsonb_build_object('tier', z.tier, 'name', z.name, 'pts', z.pts) from _gt_tiers() z where z.tier = t + 1),
                'plays', coalesce(c.plays, 0), 'wins', coalesce(c.wins, 0), 'idle', idle, 'decay', coalesce(idle > 7, false),
                'best', _gt_tname(_gt_tier(coalesce(c.best, 0)))),
    'tiers', (select jsonb_agg(jsonb_build_object('tier', z.tier, 'name', z.name, 'pts', z.pts) order by z.tier) from _gt_tiers() z),
    'board', _gt_board(u));
end $$;

-- はじめて入れたとき：これまでの記録から、カジノランク（これまでぜんぶ）と、今月のゲームランク（今月の分）を作る（知らせは出さない）
do $$
declare m int := _month_of(_now()); r record;
begin
  if exists (select 1 from gt_casino) or exists (select 1 from gt_xp) then return; end if;
  insert into gt_casino(user_id, pts, plays, wins, last_at, best)
  select t.user_id, count(*) + 2 * count(*) filter (where t.payout > t.bet), count(*), count(*) filter (where t.payout > t.bet), max(t.created_at),
         count(*) + 2 * count(*) filter (where t.payout > t.bet)
    from tx_log t join profiles p on p.id = t.user_id and p.ai is null
   where t.game in ('slot', 'blackjack', 'roulette', 'hilo', 'race', 'boat', 'keirin') and t.bet >= 10
     and coalesce(t.detail->>'refund', '') <> 'true'
   group by t.user_id;
  insert into gt_xp(user_id, month, xp, plays, wins)
  select z.user_id, m, sum(z.xp), sum(z.pl), sum(z.wn) from (
      select t.user_id,
             case when t.game in ('slot', 'blackjack', 'roulette', 'hilo') then _gt_xpb(t.bet) + case when t.payout > t.bet then 5 else 0 end
                  when t.game = 'lottery' and t.bet > 0 then _gt_xpb(t.bet)
                  when t.game in ('race', 'boat', 'keirin') and t.payout > 0 and coalesce(t.detail->>'refund', '') <> 'true' then 5 else 0 end xp,
             case when t.game in ('slot', 'blackjack', 'roulette', 'hilo') then 1 else 0 end pl,
             case when (t.game in ('slot', 'blackjack', 'roulette', 'hilo') and t.payout > t.bet)
                    or (t.game in ('race', 'boat', 'keirin') and t.payout > 0 and coalesce(t.detail->>'refund', '') <> 'true') then 1 else 0 end wn
        from tx_log t where t.created_at >= _month_start(m)
      union all
      select k.user_id, _gt_xpb(k.amount), 1, 0 from keiba_tickets k where k.created_at >= _month_start(m)
      union all
      select k.user_id, _gt_xpb(k.amount), 1, 0 from pr_tickets k where k.created_at >= _month_start(m)
      union all
      select f.user_id, 5, 0, 0 from fi_catches f where f.at >= _month_start(m)
      union all
      select s.u, 30 + case when s.w then 20 else 0 end, 1, case when s.w then 1 else 0 end
        from (select g.seats[i] u, g.winner = i - 1 w from game_rooms g, generate_series(1, cardinality(g.seats)) i
               where g.status = 'finished' and g.finished_at >= _month_start(m) and g.started_at is not null
                 and g.finished_at - g.started_at >= interval '60 seconds' and g.seats[i] is not null) s
    ) z join profiles p on p.id = z.user_id and p.ai is null
   group by z.user_id having sum(z.xp) > 0;
  for r in select x.user_id, _gt_lv(x.xp) lv from gt_xp x where x.month = m loop
    insert into gt_titles(user_id, lv, month, at) select r.user_id, t.lv, m, _now() from _gt_titles() t where t.lv <= r.lv on conflict do nothing;
  end loop;
end $$;

-- =====================================================================
-- 会社が株を持つ（法人の株主）・子会社
--   会社ごとに「株を持つための口座」（ai = 'corp' のアカウント。companies.holder）を作り、corp_holders ではその口座が株主になる
--   人や会社が、会社のID（3けた）あてに株をゆずる・売る（代金つきの申し出）と、その会社の持ち株になる
--   社長が会社の名前で、会社の持ち株を人や会社にゆずる・売る。会社あての申し出には、社長が会社のお金で払って受け取る
--   配当・残ったお金の分配は会社のお金に入る。自社株（自分の会社の株）も持てるが、配当・分配は出ない（ほかの株主で分ける）
--   子会社：別の会社が、株（自社株をのぞく）の半分より多くを持っている会社（_corp_parent・_corp_subs）
--   会社が廃業・倒産したら、持っていた株は、その会社の株主に持ち株の割合で（端数は社長）
-- =====================================================================
-- 会社の「株を持つための口座」（なければ作る）
create or replace function public._corp_hold_uid(cid_int int) returns uuid
language plpgsql set search_path = public as $$
declare c companies; g uuid; cols text[];
begin
  select * into c from companies where id = cid_int for update;
  if not found then raise exception '会社が見つかりません'; end if;
  if c.holder is not null then return c.holder; end if;
  if c.ai then raise exception 'AIの会社は株を持てません'; end if;
  g := gen_random_uuid();
  select array_agg(column_name::text) into cols from information_schema.columns where table_schema = 'auth' and table_name = 'users';
  if 'email' = any(cols) and 'confirmation_token' = any(cols) and 'banned_until' = any(cols) then
    execute 'insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
               confirmation_token, recovery_token, email_change_token_new, email_change, banned_until)
             values ($1, ''00000000-0000-0000-0000-000000000000'', ''authenticated'', ''authenticated'', $2,
               ''{"provider":"ai","providers":["ai"]}''::jsonb, ''{"ai":true}''::jsonb, now(), now(), '''', '''', '''', '''', ''2999-12-31'')'
      using g, 'corp-' || c.id || '@ailinax.invalid';
  elsif 'email' = any(cols) then
    execute 'insert into auth.users (id, email) values ($1, $2)' using g, 'corp-' || c.id || '@ailinax.invalid';
  else
    execute 'insert into auth.users (id) values ($1)' using g;
  end if;
  insert into profiles(id, nickname, balance, created_at, ai) values (g, c.name, 0, _now(), 'corp');
  update companies set holder = g where id = c.id;
  return g;
end $$;

-- 念のため：株を持つための口座にお金が入ったら（配当・分配など）、会社のお金へ（会社がもう活動していなければ社長へ）
create or replace function public._corp_hold_money() returns trigger
language plpgsql set search_path = public as $$
declare c companies; dx bigint := coalesce(new.balance, 0) - coalesce(old.balance, 0); dc numeric := coalesce(new.ca, 0) - coalesce(old.ca, 0);
begin
  if dx = 0 and dc = 0 then return new; end if;
  select * into c from companies where holder = new.id;
  if not found then return new; end if;
  if c.status in ('active', 'suspended') then
    if dx <> 0 then perform _corp_move(c.id, dx, 'holding', '持ち株の口座から（配当・分配など）'); end if;
    if dc <> 0 then update companies set ca = ca + dc where id = c.id; end if;
  else
    update profiles set balance = balance + dx, ca = ca + dc where id = c.owner;
  end if;
  new.balance := old.balance; new.ca := old.ca;
  return new;
end $$;
drop trigger if exists corp_hold_money on public.profiles;
create trigger corp_hold_money before update of balance, ca on public.profiles
  for each row when (new.ai = 'corp') execute function public._corp_hold_money();

-- 社長：会社の持ち株を、人や会社にゆずる（代金 0）・売る（代金つきの申し出）
create or replace function public.corp_share_offer(p_from text, p_cid text, p_to text, p_shares bigint, p_price bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); f companies; c companies; mine bigint; t record; to_u uuid; tc companies; me profiles; unit text;
begin
  f := _my_corp(u, p_from);
  if f.status not in ('active', 'suspended') then raise exception 'この会社はいま動かせません（審査中・廃業など）'; end if;
  if (select official from companies where cid = _cid_norm(p_cid)) then raise exception '国営の会社には株がありません'; end if;
  select * into c from companies where cid = _cid_norm(p_cid) and status in ('active', 'suspended');
  if not found then raise exception '会社が見つかりません'; end if;
  if p_shares is null or p_shares < 1 then raise exception 'ゆずる数を入れてください'; end if;
  perform 1 from companies where id = f.id for update;
  select shares into mine from corp_holders where company_id = c.id and user_id = f.holder for update;
  if f.holder is null or coalesce(mine, 0) < p_shares then raise exception 'ゆずれるのは会社が持っている % までです', coalesce(mine, 0); end if;
  select * into t from _find_id(p_to);
  if t.rid is null then
    if t.rcomp = f.id then raise exception '同じ会社にはゆずれません'; end if;
    to_u := _corp_hold_uid(t.rcomp);
    select * into tc from companies where id = t.rcomp;
  else
    to_u := t.rid;
  end if;
  unit := case when c.form = '株式会社' then '株' else '出資' end;
  select * into me from profiles where id = u;
  if coalesce(p_price, 0) = 0 then
    update corp_holders set shares = shares - p_shares where company_id = c.id and user_id = f.holder;
    delete from corp_holders where company_id = c.id and shares <= 0;
    perform _add_shares(c.id, to_u, p_shares);
    insert into corp_ledger(company_id, kind, amount, memo, balance_after)
    values (f.id, 'shares_out', 0, format('「%s」の%s %s を「%s」にゆずった', c.name, unit, _fmt(p_shares), coalesce(tc.name, t.rname)), (select balance from companies where id = f.id));
    if tc.id is not null then
      insert into corp_ledger(company_id, kind, amount, memo, balance_after)
      values (tc.id, 'shares_in', 0, format('「%s」の%s %s を受け取った', c.name, unit, _fmt(p_shares)), (select balance from companies where id = tc.id));
      if tc.owner <> u then
        perform _notice(tc.owner, format('【株】会社「%s」から、会社「%s」が「%s」の%s %s をゆずり受けました。', f.name, tc.name, c.name, unit, _fmt(p_shares)));
      end if;
    elsif to_u <> u then
      perform _notice(to_u, format('【株】会社「%s」から「%s」の%s %s をゆずり受けました。', f.name, c.name, unit, _fmt(p_shares)));
    end if;
    return my_stocks();
  end if;
  -- 代金つき：相手（会社なら社長）に申し出が届き、相手が払うと株が動く
  if p_price < 0 or p_price > 1000000000000 then raise exception '代金は0〜1兆 X にしてください'; end if;
  if _now() < coalesce(me.ok7_at, me.created_at + interval '7 days') then raise exception '登録から7日たつまで、代金つきの譲渡はできません'; end if;
  if (select count(*) from share_offers where from_user = f.holder and status = 'open') >= 20 then raise exception '返事待ちの申し出は20件までです'; end if;
  insert into share_offers(company_id, from_user, to_user, shares, price, created_at) values (c.id, f.holder, to_u, p_shares, p_price, _now());
  if tc.id is not null then
    perform _notice(tc.owner, format('【株の譲渡】会社「%s」から、会社「%s」あてに「%s」の%s %s を %s X でゆずりたいという申し出が来ました。企業タブの「持ち株」から返事できます。',
                    f.name, tc.name, c.name, unit, _fmt(p_shares), _fmt(p_price)));
  else
    perform _notice(to_u, format('【株の譲渡】会社「%s」から「%s」の%s %s を %s X でゆずりたいという申し出が来ました。企業タブの「持ち株」から返事できます。',
                    f.name, c.name, unit, _fmt(p_shares), _fmt(p_price)));
  end if;
  return my_stocks();
end $$;


-- =====================================================================
-- 新東京競馬競市（せり）と、馬の育成（所持馬）
--   せり：運営（管理者・副管理者）がイベントとして、馬名・能力などを決めて1頭ずつ出品する。10分〜5日。はじまりの値・即決の値
--         競市の会社（app_settings の horse_co）が営業中のときだけ値をつけられる。出品した人は、その馬に値をつけられない
--         AI投資家も値をつける（馬ごと・AIごとに見立てがちがう。見立てより高くなったら降りる）
--   お金：落札・即決の代金、エサ代、調教代、獣医代、売り出しの手数料は競市の会社に入る（会社がないときは国庫）
--   育成（kb_care）：能力（スピード・スタミナ・パワー・根性・賢さ 0〜100）・素質（のびしろ）・成長型・体質・寿命
--         調子（1〜5）・疲れ（0〜100）・エサ（ふつう・上・特上）・出走の方針（おまかせ・登録したレースだけ・休ませる）
--         調教は1日1回（坂路・ウッド・併せ馬・ゲート・プール・芝・ダート・休養）。病気・けが（獣医にみせると早く治る）
--         毎朝6時：エサ代、調子と疲れ、病気、寿命。毎月：年をとって成長・おとろえ。レースのあと：疲れ・けが・出走手当
--         レースの力（keiba_horses.ability など）は、ここから計算して入れる（レースのしくみはそのまま）
--   持てる馬の数は無制限。引退した馬は牧場ですごし（費用なし）、寿命で死ぬ
-- =====================================================================
alter table public.kb_sales add column if not exists buy_now bigint;          -- 即決の値（なければ null）
alter table public.kb_sales add column if not exists note text;               -- イベントの説明
alter table public.kb_sales add column if not exists show text;               -- 見せ方 exact（数字）/ grade（ランク）/ hidden（見立てだけ）
alter table public.kb_sales add column if not exists created_by uuid references public.profiles(id) on delete set null;
alter table public.kb_sales add column if not exists event boolean not null default false;   -- 運営が出品したせり
create index if not exists kb_sales_event_idx on public.kb_sales(event, status, ends_at);

create table if not exists public.kb_care (
  horse_id    int primary key references public.keiba_horses(id) on delete cascade,
  spd         numeric not null,            -- スピード
  sta         numeric not null,            -- スタミナ
  pow         numeric not null,            -- パワー
  guts        numeric not null,            -- 根性
  wis         numeric not null,            -- 賢さ
  pot         numeric not null,            -- 素質（能力がのびる上限。見せない）
  health      numeric not null default 1,  -- 体質（1が標準。大きいほど病気・けがをしにくい。見せない）
  dist0       int not null,                -- 距離のもと（スタミナとスピードの差で少し動く）
  grow        text not null default 'normal',   -- 成長型 early / normal / late
  life        int not null,                -- 寿命（歳。見せない）
  cond        int not null default 3,      -- 調子 1〜5
  fatigue     int not null default 0,      -- 疲れ 0〜100
  feed        text not null default 'normal',   -- エサ normal / good / best
  mode        text not null default 'auto',     -- 出走 auto（おまかせ）/ reg（登録したレースだけ）/ rest（休ませる）
  ill         text,                        -- 病気・けが（cold・fever・shin・colic・tendon・fracture）
  ill_until   date,
  ill_treated boolean not null default false,
  trained_on  date,
  train_n     int not null default 0,
  last_race   bigint not null default 0,   -- 疲れ・けが・出走手当を数えた最後のレース
  grew_month  int,                         -- 年をとった分の成長を入れた月
  dead_at     timestamptz,
  dead_why    text,
  bought      bigint,                      -- 買った値
  cost_total  bigint not null default 0,   -- これまでの費用（エサ・調教・獣医）
  created_at  timestamptz not null default now()
);
alter table public.kb_care enable row level security;
revoke all on public.kb_care from anon, authenticated;

-- 調教のメニュー・病気・エサ・出走手当
create or replace function public._hc_c() returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'menus', jsonb_build_object(
      'hill',  jsonb_build_object('name', '坂路', 'fee', 120, 'spd', 1.2, 'pow', 1.2, 'fat', 18, 'inj', 0.004),
      'wood',  jsonb_build_object('name', 'ウッドコース', 'fee', 100, 'sta', 1.5, 'guts', 0.6, 'fat', 15, 'inj', 0.003),
      'spar',  jsonb_build_object('name', '併せ馬', 'fee', 200, 'guts', 1.5, 'spd', 0.8, 'wis', 0.3, 'fat', 22, 'inj', 0.006),
      'gate',  jsonb_build_object('name', 'ゲート練習', 'fee', 60, 'wis', 1.4, 'fat', 6, 'inj', 0.001),
      'pool',  jsonb_build_object('name', 'プール', 'fee', 80, 'sta', 0.6, 'fat', -15, 'inj', 0),
      'turf',  jsonb_build_object('name', '芝コース', 'fee', 100, 'spd', 0.6, 'turf', 0.03, 'fat', 12, 'inj', 0.003),
      'dirt',  jsonb_build_object('name', 'ダートコース', 'fee', 100, 'pow', 0.6, 'turf', -0.03, 'fat', 12, 'inj', 0.003),
      'rest',  jsonb_build_object('name', '休養', 'fee', 0, 'fat', -25, 'inj', 0)),
    'ills', jsonb_build_object(
      'cold',     jsonb_build_object('name', '風邪', 'd1', 2, 'd2', 4, 'vet', 300, 'die', 0),
      'fever',    jsonb_build_object('name', '熱発', 'd1', 2, 'd2', 3, 'vet', 400, 'die', 0),
      'shin',     jsonb_build_object('name', 'ソエ', 'd1', 3, 'd2', 6, 'vet', 500, 'die', 0),
      'colic',    jsonb_build_object('name', '疝痛', 'd1', 3, 'd2', 5, 'vet', 2000, 'die', 0.2),
      'tendon',   jsonb_build_object('name', '屈腱炎', 'd1', 20, 'd2', 40, 'vet', 3000, 'die', 0),
      'fracture', jsonb_build_object('name', '骨折', 'd1', 25, 'd2', 50, 'vet', 5000, 'die', 0)),
    'feeds', jsonb_build_object('normal', jsonb_build_object('name', 'ふつう', 'fee', 40),
                                'good', jsonb_build_object('name', '上', 'fee', 100),
                                'best', jsonb_build_object('name', '特上', 'fee', 250)),
    'appear', jsonb_build_array(60, 80, 100, 120, 150), 'appear_g3', 200, 'appear_g1', 300,
    'min_minutes', 10, 'max_minutes', 7200)
$$;

-- 競市の会社（設定がなければ null）
create or replace function public._hx_co() returns companies
language sql stable set search_path = public as $$
  select c.* from companies c where c.id::text = (select value from app_settings where key = 'horse_co') $$;
-- 馬のお金（落札・エサ代など）を競市の会社に入れる。人が払った分は _log で国庫に入っているので、国庫から会社へうつす
-- （AIが払った分は記録しないので、そのまま会社へ）。会社がない・やめたときは国庫のまま
create or replace function public._hx_paid(u uuid, amt bigint, k text, memo text) returns void
language plpgsql set search_path = public as $$
declare c companies := _hx_co(); isai boolean := exists (select 1 from profiles p where p.id = u and p.ai is not null);
begin
  if coalesce(amt, 0) <= 0 then return; end if;
  if c.id is null or c.status not in ('active', 'suspended') then
    if isai then update treasury set balance = balance + amt where id = 1; end if;
    return;
  end if;
  if not isai then update treasury set balance = balance - amt, casino_total = casino_total - amt where id = 1; end if;
  perform _corp_move(c.id, amt, k, memo);
end $$;

-- 能力 0〜100 をランクに
create or replace function public._hc_grade(v numeric) returns text
language sql immutable as $$
  select case when v >= 90 then 'S' when v >= 80 then 'A' when v >= 70 then 'B' when v >= 60 then 'C'
              when v >= 50 then 'D' when v >= 40 then 'E' when v >= 30 then 'F' else 'G' end $$;
-- 能力のまとめ（重みつき平均）
create or replace function public._hc_avg(k public.kb_care) returns numeric
language sql immutable as $$ select 0.35 * k.spd + 0.2 * k.sta + 0.2 * k.pow + 0.15 * k.guts + 0.1 * k.wis $$;
-- 能力（くらべるため）
create or replace function public._hc_json_stats(k public.kb_care) returns jsonb
language sql immutable as $$
  select jsonb_build_object('spd', round(k.spd, 1), 'sta', round(k.sta, 1), 'pow', round(k.pow, 1), 'guts', round(k.guts, 1), 'wis', round(k.wis, 1),
                            'fatigue', k.fatigue, 'cond', k.cond) $$;

-- 育成のデータから、レースの力などを入れる（調子・疲れもこみ。年齢の分はレースのほうでかけるので、ここでわっておく）
-- 出られないとき（病気・休養・登録したレースだけ・死んだ）は barn
create or replace function public._hc_apply(hid int) returns void
language plpgsql set search_path = public as $$
declare k kb_care; h keiba_horses; ab numeric;
begin
  select * into k from kb_care where horse_id = hid;
  if not found then return; end if;
  select * into h from keiba_horses where id = hid;
  if not found then return; end if;
  ab := (10 + 0.75 * _hc_avg(k)
         + (array[-3, -1.5, 0, 1.5, 3])[greatest(1, least(5, k.cond))]
         - least(5, k.fatigue * 0.05)) / _kb_agef(_kb_midx(_now()) - h.born);
  update keiba_horses set
    ability = round(ab, 1),
    best_dist = greatest(1000, least(3600, k.dist0 + round((k.sta - k.spd) * 6)::int)),
    dist_width = 300 + round(k.wis * 3)::int,
    heavy = round(greatest(-1, least(1, (k.pow - 50) / 40.0)), 2),
    retired = retired or k.dead_at is not null,
    barn = case when h.owner is null then barn
                else k.dead_at is not null or k.ill is not null or k.mode in ('rest', 'reg') end
   where id = hid;
end $$;

-- 人の馬になったとき：育成のデータを作る（運営が出品した馬は、もうある）
create or replace function public._hc_ensure(hid int) returns void
language plpgsql set search_path = public as $$
declare h keiba_horses; a numeric; age int;
begin
  if exists (select 1 from kb_care where horse_id = hid) then return; end if;
  select * into h from keiba_horses where id = hid;
  if not found then return; end if;
  age := _kb_midx(_now()) - h.born;
  a := greatest(15, least(98, (h.ability * _kb_agef(age) - 10) / 0.75));
  insert into kb_care(horse_id, spd, sta, pow, guts, wis, pot, health, dist0, grow, life, cond, fatigue, grew_month, last_race)
  values (hid, round(a + _kb_norm() * 4, 1), round(a + _kb_norm() * 4, 1), round(a + _kb_norm() * 4, 1), round(a + _kb_norm() * 4, 1), round(a + _kb_norm() * 4, 1),
          round(least(100, a + 4 + random()::numeric * 12 - greatest(0, age - 4) * 3), 1), round(0.75 + random()::numeric * 0.5, 2),
          h.best_dist, (array['early', 'normal', 'normal', 'late'])[1 + floor(random() * 4)::int], greatest(age + 3, 22 + floor(random() * 9)::int),
          3, 0, _kb_midx(_now()),
          coalesce((select max(e.race_id) from keiba_entries e join keiba_races r on r.id = e.race_id where e.horse_id = hid and r.settled), 0))
  on conflict (horse_id) do nothing;
end $$;

-- 出られるか（登録したレースだけの馬は、休んでいなければ出られる）
create or replace function public._hc_can_run(h public.keiba_horses, p_cls int, p_cond text, d date) returns boolean
language plpgsql stable set search_path = public as $$
declare k kb_care; h2 keiba_horses := h;
begin
  select * into k from kb_care where horse_id = h.id;
  if found and h.owner is not null then
    if k.dead_at is not null or k.ill is not null or k.mode = 'rest' then return false; end if;
    h2.barn := false;
  end if;
  return _kb_can_run(h2, p_cls, p_cond, d);
end $$;

-- 病気・けがにする（barn にして、知らせる）
create or replace function public._hc_sick(hid int, what text, why text) returns void
language plpgsql set search_path = public as $$
declare k kb_care; h keiba_horses; i jsonb := _hc_c()->'ills'->what; dd int;
begin
  select * into k from kb_care where horse_id = hid for update;
  if not found or k.dead_at is not null or k.ill is not null then return; end if;
  select * into h from keiba_horses where id = hid;
  dd := (i->>'d1')::int + floor(random() * ((i->>'d2')::int - (i->>'d1')::int + 1))::int;
  update kb_care set ill = what, ill_until = _kb_jday(_now()) + dd, ill_treated = false,
         cond = greatest(1, cond - 1) where horse_id = hid;
  delete from kb_regs where horse_id = hid;
  perform _hc_apply(hid);
  if h.owner is not null then
    if (i->>'die')::numeric > 0 then
      perform _notice(h.owner, format('【馬主】「%s」が%s（%s）になりました。治るまで、あと%s日ほど。命にかかわるので、すぐ獣医にみせてください（%s X）。',
                      h.name, i->>'name', why, dd, _fmt((i->>'vet')::bigint)));
    else
      perform _notice(h.owner, format('【馬主】「%s」が%s（%s）になりました。治るまで、あと%s日ほど。獣医にみせると早く治ります（%s X）。',
                      h.name, i->>'name', why, dd, _fmt((i->>'vet')::bigint)));
    end if;
  end if;
end $$;

-- 死んだ（引退・barn。馬主には知らせる。記録は残す）
create or replace function public._hc_die(hid int, why text) returns void
language plpgsql set search_path = public as $$
declare h keiba_horses;
begin
  select * into h from keiba_horses where id = hid;
  update kb_care set dead_at = _now(), dead_why = why, ill = null, ill_until = null where horse_id = hid and dead_at is null;
  if not found then return; end if;
  delete from kb_regs where horse_id = hid;
  update kb_sales set status = 'cancel' where horse_id = hid and kind = 'resale' and status = 'open';
  perform _hc_apply(hid);
  if h.owner is not null then
    perform _notice(h.owner, format('【馬主】「%s」が%s。%s歳でした。', h.name, why, _kb_midx(_now()) - h.born));
  end if;
end $$;

-- 費用をとる（馬主から → 競市の会社へ）。足りなければ false
create or replace function public._hc_pay(u uuid, hid int, amt bigint, memo text) returns boolean
language plpgsql set search_path = public as $$
begin
  if coalesce(amt, 0) <= 0 then return true; end if;
  if coalesce(_bal(u), 0) < amt then return false; end if;
  perform _take(u, amt);
  perform _log(u, 'owner', amt, 0, jsonb_build_object('horse', hid, 'title', memo));
  perform _hx_paid(u, amt, 'horse', memo);
  update kb_care set cost_total = cost_total + amt where horse_id = hid;
  return true;
end $$;

-- 調教の中身（費用はとらない。hc_train と AI から）。けがをしたら、その種類を返す
create or replace function public._hc_do_train(hid int, menu text) returns text
language plpgsql set search_path = public as $$
declare k kb_care; h keiba_horses; m jsonb := _hc_c()->'menus'->menu; age int; f numeric; g numeric; s text; v numeric;
  inj numeric; res text;
begin
  select * into k from kb_care where horse_id = hid for update;
  select * into h from keiba_horses where id = hid;
  age := _kb_midx(_now()) - h.born;
  f := (case when age <= 2 then 1.3 when age = 3 then 1.2 when age = 4 then 1.0 when age = 5 then 0.8 when age = 6 then 0.6 else 0.35 end)
       * (case k.feed when 'best' then 1.2 when 'good' then 1.1 else 1.0 end)
       * (array[0.7, 0.85, 1.0, 1.08, 1.15])[greatest(1, least(5, k.cond))]
       * (case when k.fatigue > 70 then 0.5 else 1 end);
  foreach s in array array['spd', 'sta', 'pow', 'guts', 'wis'] loop
    if m ? s then
      v := case s when 'spd' then k.spd when 'sta' then k.sta when 'pow' then k.pow when 'guts' then k.guts else k.wis end;
      -- 素質に近づくほど、のびにくい（賢さは素質に関係なくのびる）
      g := (m->>s)::numeric * f * (0.6 + random() * 0.8)
           * case when s = 'wis' then 1 else power(greatest(0, (k.pot - v) / greatest(k.pot - 15, 5)), 0.8) end;
      v := round(least(100, v + g), 1);
      if s = 'spd' then k.spd := v; elsif s = 'sta' then k.sta := v; elsif s = 'pow' then k.pow := v; elsif s = 'guts' then k.guts := v; else k.wis := v; end if;
    end if;
  end loop;
  update kb_care set spd = k.spd, sta = k.sta, pow = k.pow, guts = k.guts, wis = k.wis,
         fatigue = greatest(0, least(100, fatigue + (m->>'fat')::int)),
         cond = case when menu = 'rest' and random() < 0.5 then least(5, cond + 1) else cond end,
         trained_on = _kb_jday(_now()), train_n = train_n + 1
   where horse_id = hid;
  if m ? 'turf' then
    update keiba_horses set turf = round(greatest(0.05, least(0.95, turf + (m->>'turf')::numeric)), 2) where id = hid;
  end if;
  -- けが（疲れているほど・体質が弱いほど）
  inj := (m->>'inj')::numeric * (1 + k.fatigue / 40.0) * (2 - k.health);
  if inj > 0 and random() < inj then
    res := case when random() < 0.7 then 'shin' else 'tendon' end;
    perform _hc_sick(hid, res, 'けいこ中');
  end if;
  perform _hc_apply(hid);
  return res;
end $$;

-- 毎朝6時（1日1回）：エサ代、寿命、病気、調子と疲れ。AIの馬は自動で調教・獣医
create or replace function public._hc_daily() returns void
language plpgsql set search_path = public as $$
declare c jsonb := _hc_c(); today date := _kb_jday(_now()); o record; r record; fee bigint; tot bigint; n int; k kb_care; p numeric; w text;
  t6 timestamptz := make_timestamptz(extract(year from _kb_jday(_now()))::int, extract(month from _kb_jday(_now()))::int, extract(day from _kb_jday(_now()))::int, 6, 0, 0, 'Asia/Tokyo');
  isai boolean; age int; tgt numeric; menu text; ills text[];
begin
  if _now() < t6 then return; end if;
  insert into kb_upkeep(day, at) values (today, _now()) on conflict (day) do nothing;
  if not found then return; end if;
  for r in select h.id from keiba_horses h where h.owner is not null and not exists (select 1 from kb_care k2 where k2.horse_id = h.id) loop
    perform _hc_ensure(r.id); perform _hc_apply(r.id);
  end loop;
  -- 馬主ごとに：エサ代（引退した馬はかからない）。払えない馬は、エサをふつうにする。それも払えなければ手放す
  for o in select h.owner from keiba_horses h join kb_care k2 on k2.horse_id = h.id
            where h.owner is not null and k2.dead_at is null and not h.retired and h.owned_at < t6 group by h.owner loop
    tot := 0; n := 0;
    for r in select h.id, h.name, k2.feed from keiba_horses h join kb_care k2 on k2.horse_id = h.id
              where h.owner = o.owner and k2.dead_at is null and not h.retired and h.owned_at < t6 order by h.owned_at, h.id loop
      fee := (c->'feeds'->r.feed->>'fee')::bigint;
      if coalesce(_bal(o.owner), 0) < fee and r.feed <> 'normal' then
        update kb_care set feed = 'normal' where horse_id = r.id;
        fee := (c->'feeds'->'normal'->>'fee')::bigint;
        perform _notice(o.owner, format('【馬主】お金が足りないので、「%s」のエサを「ふつう」にしました。', r.name));
      end if;
      if coalesce(_bal(o.owner), 0) >= fee then
        perform _take(o.owner, fee);
        update kb_care set cost_total = cost_total + fee where horse_id = r.id;
        tot := tot + fee; n := n + 1;
      else
        perform _kb_release(r.id);
        perform _notice(o.owner, format('【馬主】エサ代（1日 %s X）が払えなかったので、「%s」を手放しました。', fee, r.name));
      end if;
    end loop;
    if tot > 0 then
      perform _log(o.owner, 'owner', tot, 0, jsonb_build_object('upkeep', n, 'day', today, 'title', format('エサ代 %s頭', n)));
      perform _hx_paid(o.owner, tot, 'horse', format('エサ代 %s頭（%s）', n, today));
    end if;
  end loop;
  -- 1頭ずつ：寿命・病気・調子と疲れ
  for r in select h.id, h.name, h.owner, h.retired, h.born from keiba_horses h join kb_care k2 on k2.horse_id = h.id
            where h.owner is not null and k2.dead_at is null order by h.id loop
    select * into k from kb_care where horse_id = r.id for update;
    age := _kb_midx(_now()) - r.born;
    isai := exists (select 1 from profiles pp where pp.id = r.owner and pp.ai is not null);
    -- 寿命
    if age >= k.life then perform _hc_die(r.id, '天寿をまっとうしました'); continue; end if;
    -- AIの引退した馬は、牧場にかえす
    if isai and r.retired then perform _kb_release(r.id); continue; end if;
    -- 病気・けが
    if k.ill is not null then
      p := (c->'ills'->k.ill->>'die')::numeric;
      if not k.ill_treated and p > 0 and random() < p then perform _hc_die(r.id, (c->'ills'->k.ill->>'name') || 'で死んでしまいました'); continue; end if;
      if isai and not k.ill_treated then
        if _hc_pay(r.owner, r.id, (c->'ills'->k.ill->>'vet')::bigint, format('獣医代（%s・%s）', r.name, c->'ills'->k.ill->>'name')) then
          update kb_care set ill_treated = true, ill_until = greatest(today + 1, today + ceil((ill_until - today) / 2.0)::int) where horse_id = r.id;
        end if;
      end if;
      select * into k from kb_care where horse_id = r.id;
      if k.ill_until <= today then
        if k.ill = 'fracture' and not k.ill_treated and not r.retired and random() < 0.5 then
          update kb_care set ill = null, ill_until = null where horse_id = r.id;
          update keiba_horses set retired = true where id = r.id;
          delete from kb_regs where horse_id = r.id;
          perform _notice(r.owner, format('【馬主】「%s」の骨折は治りましたが、手当てがおくれたので、もう走れません。引退しました。', r.name));
        else
          update kb_care set ill = null, ill_until = null, ill_treated = false where horse_id = r.id;
          perform _notice(r.owner, format('【馬主】「%s」の%sが治りました。', r.name, c->'ills'->k.ill->>'name'));
        end if;
      end if;
    elsif not r.retired then
      -- 病気になるか（疲れ・体質・エサ・年）
      p := 0.008 * (2 - k.health) * (1 + k.fatigue / 60.0) * (case k.feed when 'best' then 0.7 when 'good' then 0.85 else 1 end) * (case when age >= 7 then 1.4 else 1 end);
      if random() < p then
        ills := array['cold', 'cold', 'cold', 'cold', 'fever', 'fever', 'fever', 'colic'];
        if k.fatigue > 40 then ills := ills || array['shin', 'shin']; end if;
        if k.fatigue > 50 then ills := ills || array['tendon']; end if;
        w := ills[1 + floor(random() * array_length(ills, 1))::int];
        perform _hc_sick(r.id, w, '朝の検査で');
      end if;
    end if;
    -- 調子と疲れ（休んでいるほど・エサがいいほど、よくなる）
    if not r.retired then
      select * into k from kb_care where horse_id = r.id;
      tgt := 3 + case k.feed when 'best' then 0.7 when 'good' then 0.35 else 0 end - case when k.fatigue > 60 then 1.2 when k.fatigue > 40 then 0.5 else 0 end
              + case when k.mode = 'rest' then 0.5 else 0 end - case when k.ill is not null then 1 else 0 end;
      update kb_care set
        fatigue = greatest(0, fatigue - 10 - case feed when 'best' then 5 when 'good' then 2 else 0 end - case when mode = 'rest' then 8 else 0 end),
        cond = greatest(1, least(5, cond + case when random() < 0.55 then sign(round(tgt) - cond)::int else (array[-1, 0, 1])[1 + floor(random() * 3)::int] end))
       where horse_id = r.id;
      -- AIの馬：自動で調教（疲れていれば軽め）
      if isai and k.ill is null and (k.trained_on is null or k.trained_on < today) then
        menu := case when k.fatigue >= 55 then 'rest' when k.fatigue >= 35 then 'pool'
                     else (array['hill', 'wood', 'spar', 'gate'])[1 + floor(random() * 4)::int] end;
        if _hc_pay(r.owner, r.id, (c->'menus'->menu->>'fee')::bigint, format('調教代（%s・%s）', r.name, c->'menus'->menu->>'name')) then
          perform _hc_do_train(r.id, menu);
        end if;
      end if;
    end if;
    perform _hc_apply(r.id);
  end loop;
end $$;

-- 毎月（年をとった）：成長型ごとに、のびる・おとろえる
create or replace function public._hc_monthly() returns void
language plpgsql set search_path = public as $$
declare m int := _kb_midx(_now()); r record; age int; d numeric;
begin
  for r in select k.*, h.born from kb_care k join keiba_horses h on h.id = k.horse_id
            where k.dead_at is null and h.owner is not null and coalesce(k.grew_month, 0) < m loop
    age := m - r.born;
    d := case r.grow
           when 'early' then case when age <= 3 then 4 when age = 4 then 1 when age = 5 then -2 when age = 6 then -4 else -6 end
           when 'late'  then case when age <= 3 then 2 when age = 4 then 4 when age = 5 then 3 when age = 6 then 0 else -3 end
           else              case when age <= 3 then 3 when age = 4 then 3 when age = 5 then 0 when age = 6 then -3 else -5 end end;
    update kb_care set
      spd  = round(greatest(10, case when d > 0 then least(spd + d, greatest(spd, pot)) else spd + d end), 1),
      sta  = round(greatest(10, case when d > 0 then least(sta + d, greatest(sta, pot)) else sta + d end), 1),
      pow  = round(greatest(10, case when d > 0 then least(pow + d, greatest(pow, pot)) else pow + d end), 1),
      guts = round(greatest(10, case when d > 0 then least(guts + d * 0.5, greatest(guts, pot)) else guts + d * 0.5 end), 1),
      wis  = round(greatest(10, least(100, wis + case when d > 0 then 1 else 0.5 end)), 1),
      grew_month = m
     where horse_id = r.horse_id;
    perform _hc_apply(r.horse_id);
  end loop;
end $$;

-- 毎分：終わったレースの疲れ・調子・けが・出走手当（レースのしくみはさわらない）
create or replace function public._hc_after_races() returns void
language plpgsql set search_path = public as $$
declare r record; k kb_care; p numeric; fee bigint; c jsonb := _hc_c();
begin
  for r in select k2.horse_id, e.race_id, e.pos, e.incident, kr.dist, kr.grade, kr.cls, h.name, h.owner
             from kb_care k2 join keiba_horses h on h.id = k2.horse_id
             join keiba_entries e on e.horse_id = k2.horse_id and e.race_id > k2.last_race
             join keiba_races kr on kr.id = e.race_id and kr.settled
            where k2.dead_at is null and h.owner is not null
            order by e.race_id loop
    select * into k from kb_care where horse_id = r.horse_id for update;
    continue when r.race_id <= k.last_race;
    update kb_care set last_race = r.race_id where horse_id = r.horse_id;
    continue when r.incident is not distinct from 'jogai';
    update kb_care set
           fatigue = least(100, fatigue + 25 + case when r.dist >= 2400 then 8 when r.dist >= 2000 then 4 else 0 end),
           cond = greatest(1, least(5, cond + case when r.pos = 1 then 1 when r.pos is null then -1 else (array[-1, 0, 0, 1])[1 + floor(random() * 4)::int] end))
     where horse_id = r.horse_id;
    -- 出走手当（走った馬みんなに。クラス・格で決まる）
    fee := case when r.grade = 'G1' then (c->>'appear_g1')::bigint when r.grade in ('G2', 'G3') then (c->>'appear_g3')::bigint
                when r.grade in ('L', 'OP') or r.cls is null then (c->'appear'->>4)::bigint
                else (c->'appear'->>least(4, greatest(0, r.cls)))::bigint end;
    perform _give(r.owner, fee);
    perform _log(r.owner, 'owner', 0, fee, jsonb_build_object('race', r.race_id, 'horse', r.horse_id, 'appear', true, 'title', format('「%s」出走手当', r.name)));
    update keiba_horses set earned = earned + fee where id = r.horse_id;
    -- レースでのけが
    p := random();
    if p < 0.002 * (1 + k.fatigue / 50.0) * (2 - k.health) then
      perform _hc_sick(r.horse_id, 'fracture', 'レースで');
    elsif p < 0.007 * (1 + k.fatigue / 50.0) * (2 - k.health) then
      perform _hc_sick(r.horse_id, 'tendon', 'レースで');
    end if;
    perform _hc_apply(r.horse_id);
  end loop;
end $$;

-- 馬主に見せる育成のようす
create or replace function public._hc_json(hid int) returns jsonb
language plpgsql stable set search_path = public as $$
declare k kb_care; h keiba_horses; today date := _kb_jday(_now()); room numeric;
begin
  select * into k from kb_care where horse_id = hid;
  if not found then return null; end if;
  select * into h from keiba_horses where id = hid;
  room := k.pot - greatest(k.spd, k.sta, k.pow, k.guts);
  return _hc_json_stats(k) || jsonb_build_object(
    'total', round(_hc_avg(k), 1), 'feed', k.feed, 'mode', k.mode, 'grow', k.grow,
    'room', case when room >= 15 then 'big' when room >= 6 then 'mid' when room >= 2 then 'small' else 'none' end,
    'ill', k.ill, 'ill_days', case when k.ill is not null then greatest(0, k.ill_until - today) end, 'ill_treated', k.ill_treated,
    'trained', k.trained_on is not distinct from today, 'train_n', k.train_n,
    'dist', h.best_dist, 'width', h.dist_width, 'turf', h.turf, 'heavy', h.heavy,
    'dead', k.dead_at is not null, 'dead_why', k.dead_why, 'dead_ms', _kb_ms(k.dead_at),
    'bought', k.bought, 'cost', k.cost_total);
end $$;

-- 運営の出品：見せる中身
create or replace function public._hx_info(k public.kb_care, h public.keiba_horses, how text) returns jsonb
language plpgsql volatile set search_path = public as $$
declare s numeric; bd numeric; t numeric;
begin
  if how = 'exact' then
    return jsonb_build_object('show', how, 'spd', round(k.spd), 'sta', round(k.sta), 'pow', round(k.pow), 'guts', round(k.guts), 'wis', round(k.wis),
                              'pot', _hc_grade(k.pot), 'grow', k.grow, 'dist', h.best_dist, 'turf', h.turf);
  elsif how = 'grade' then
    return jsonb_build_object('show', how, 'spd', _hc_grade(k.spd), 'sta', _hc_grade(k.sta), 'pow', _hc_grade(k.pow), 'guts', _hc_grade(k.guts),
                              'wis', _hc_grade(k.wis), 'grow', k.grow, 'dist', h.best_dist, 'turf', h.turf);
  end if;
  s := _hc_avg(k) * 0.7 + k.pot * 0.3 + _kb_norm() * 5;
  bd := h.best_dist + _kb_norm() * 250;
  t := h.turf + _kb_norm() * 0.15;
  return jsonb_build_object('show', 'hidden',
    'eval', case when s >= 75 then 'S' when s >= 64 then 'A' when s >= 55 then 'B' when s >= 46 then 'C' else 'D' end,
    'dist', case when bd < 1500 then 'short' when bd < 1900 then 'mile' when bd < 2300 then 'mid' else 'long' end,
    'turf', case when t >= 0.62 then 'turf' when t <= 0.38 then 'dirt' else 'both' end);
end $$;

-- 運営：出品のようす（ぜんぶ見える）
create or replace function public.hx_admin_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); co companies := _hx_co();
begin
  if _role(u) is null then raise exception '管理者・副管理者だけです'; end if;
  perform _kb_sales_tick();
  return jsonb_build_object(
    'co', case when co.id is not null then jsonb_build_object('cid', co.cid, 'name', co.name, 'status', co.status) end,
    'lots', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', h.name, 'sex', h.sex, 'age', _kb_midx(_now()) - h.born,
               'status', s.status, 'start', s.start_price, 'buy_now', s.buy_now, 'price', s.price, 'nbids', s.nbids,
               'top', (select p.nickname from profiles p where p.id = s.top), 'top_ai', (select p.ai is not null from profiles p where p.id = s.top),
               'buyer', (select p.nickname from profiles p where p.id = s.buyer), 'sold_price', s.sold_price,
               'by', (select p.nickname from profiles p where p.id = s.created_by), 'mine', s.created_by = u,
               'opens_ms', _kb_ms(s.opens_at), 'ends_ms', _kb_ms(s.ends_at), 'show', s.show, 'note', s.note,
               'stats', case when k.horse_id is not null then jsonb_build_object('spd', k.spd, 'sta', k.sta, 'pow', k.pow, 'guts', k.guts, 'wis', k.wis, 'pot', k.pot, 'grow', k.grow) end)
               order by s.id desc), '[]'::jsonb)
               from (select * from kb_sales where event order by id desc limit 40) s join keiba_horses h on h.id = s.horse_id
               left join kb_care k on k.horse_id = s.horse_id),
    'now_ms', _kb_ms(_now()));
end $$;

-- 運営の出品：つくる（p_spec：name sex age cls coat sire dam spd sta pow guts wis pot dist surface style grow body show start buy_now opens_at minutes note）
create or replace function public.hx_admin_create(p_spec jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); n text := translate(btrim(coalesce(p_spec->>'name', '')), 'ｰ', 'ー'); sx text := p_spec->>'sex';
  age int := coalesce(nullif(p_spec->>'age', '')::int, 2); cl int := coalesce(nullif(p_spec->>'cls', '')::int, 0);
  mins int := coalesce(nullif(p_spec->>'minutes', '')::int, 60);
  st bigint := nullif(p_spec->>'start', '')::bigint; bn bigint := nullif(p_spec->>'buy_now', '')::bigint;
  op timestamptz := coalesce(nullif(p_spec->>'opens_at', '')::timestamptz, _now());
  how text := coalesce(p_spec->>'show', 'grade'); hid int; k kb_care; h keiba_horses; sf text := coalesce(p_spec->>'surface', '芝');
  colors text[] := _kb_colors(); c1 text; c2 text; v numeric; x text;
begin
  if _role(u) is null then raise exception '出品できるのは管理者・副管理者だけです'; end if;
  if n !~ '^[ァ-ヴー]{2,9}$' then raise exception '馬名はカタカナ2〜9文字にしてください'; end if;
  if exists (select 1 from keiba_horses where name = n) then raise exception 'その名前の馬はもういます'; end if;
  if sx is null or sx not in ('牡', '牝', 'セ') then raise exception '性別をえらんでください'; end if;
  if age not between 2 and 6 then raise exception '年齢は2〜6歳にしてください'; end if;
  if cl not between 0 and 4 then raise exception 'クラスをえらんでください'; end if;
  if age >= 4 and cl = 0 then raise exception '4歳以上の馬は、1勝クラスより上にしてください（未勝利のまま4歳になると引退です）'; end if;
  foreach x in array array['spd', 'sta', 'pow', 'guts', 'wis', 'pot'] loop
    v := nullif(p_spec->>x, '')::numeric;
    if v is null or v < 1 or v > 100 then raise exception '能力・素質は1〜100で入れてください'; end if;
  end loop;
  if coalesce(nullif(p_spec->>'dist', '')::int, 0) not between 1000 and 3600 then raise exception '距離は1000〜3600mで入れてください'; end if;
  if sf not in ('芝', 'ダ', '両') then raise exception '芝・ダートをえらんでください'; end if;
  if coalesce(nullif(p_spec->>'style', '')::int, -1) not between 0 and 3 then raise exception '脚質をえらんでください'; end if;
  if coalesce(p_spec->>'grow', '') not in ('early', 'normal', 'late') then raise exception '成長型をえらんでください'; end if;
  if how not in ('exact', 'grade', 'hidden') then raise exception '見せ方をえらんでください'; end if;
  if st is null or st < 1 or st > 100000000 then raise exception 'はじまりの値は1〜1億 X にしてください'; end if;
  if bn is not null and (bn <= st or bn > 1000000000) then raise exception '即決の値は、はじまりの値より大きく、10億 X までにしてください'; end if;
  if mins < 10 or mins > 7200 then raise exception 'せりの長さは10分〜5日にしてください'; end if;
  if op < _now() - interval '5 minutes' or op > _now() + interval '30 days' then raise exception 'はじまりは、いまから30日以内にしてください'; end if;
  op := greatest(op, _now());
  c1 := colors[1 + floor(random() * array_length(colors, 1))::int];
  loop c2 := colors[1 + floor(random() * array_length(colors, 1))::int]; exit when c2 <> c1; end loop;
  insert into keiba_horses(name, sex, born, coat, silk1, silk2, silk_pat, ability, style, best_dist, dist_width, turf, heavy, body, class, wins, starts, prize, barn, named)
  values (n, sx, _kb_midx(_now()) - age, greatest(0, least(5, coalesce(nullif(p_spec->>'coat', '')::int, 0))), c1, c2, floor(random() * 7)::int,
          45, (p_spec->>'style')::int, (p_spec->>'dist')::int, 400, case sf when '芝' then 0.8 when 'ダ' then 0.2 else 0.5 end, 0,
          greatest(400, least(560, coalesce(nullif(p_spec->>'body', '')::int, 470))), cl, cl, cl * 2,
          case cl when 0 then 0 when 1 then 550 when 2 then 1350 when 3 then 2450 else 3950 end, true, true)
  returning id into hid;
  insert into kb_care(horse_id, spd, sta, pow, guts, wis, pot, health, dist0, grow, life, cond, fatigue, grew_month, last_race)
  values (hid, (p_spec->>'spd')::numeric, (p_spec->>'sta')::numeric, (p_spec->>'pow')::numeric, (p_spec->>'guts')::numeric, (p_spec->>'wis')::numeric,
          greatest((p_spec->>'pot')::numeric, (p_spec->>'spd')::numeric, (p_spec->>'sta')::numeric, (p_spec->>'pow')::numeric, (p_spec->>'guts')::numeric),
          round(0.8 + random()::numeric * 0.4, 2), (p_spec->>'dist')::int, p_spec->>'grow', 22 + floor(random() * 9)::int, 3, 0, _kb_midx(_now()), 0);
  perform _hc_apply(hid);
  update keiba_horses set barn = true where id = hid;
  select * into k from kb_care where horse_id = hid;
  select * into h from keiba_horses where id = hid;
  insert into kb_sales(horse_id, kind, opens_at, ends_at, start_price, buy_now, note, show, created_by, event, info)
  values (hid, 'auction', op, op + make_interval(mins => mins), st, bn, left(btrim(coalesce(p_spec->>'note', '')), 300), how, u, true,
          _hx_info(k, h, how) || jsonb_build_object('sire', left(btrim(coalesce(p_spec->>'sire', '')), 20), 'dam', left(btrim(coalesce(p_spec->>'dam', '')), 20)));
  return hx_admin_state();
end $$;

-- 運営：せりを取り消す（つけていた値は返す。まだ走っていない馬なので、馬ごと消す）
create or replace function public.hx_admin_cancel(p_sale bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); s kb_sales; nm text;
begin
  if _role(u) is null then raise exception '管理者・副管理者だけです'; end if;
  select * into s from kb_sales where id = p_sale and event for update;
  if not found or s.status <> 'open' then raise exception '取り消せるせりが見つかりません'; end if;
  select name into nm from keiba_horses where id = s.horse_id;
  if s.top is not null then
    perform _give(s.top, s.price);
    perform _log(s.top, 'owner_back', 0, s.price, jsonb_build_object('sale', s.id, 'horse', s.horse_id, 'title', format('「%s」のせりの取り消し', nm)));
    perform _notice(s.top, format('【せり】「%s」のせりは取り消しになりました。あずけていた %s X は返しました。', nm, _fmt(s.price)));
  end if;
  update kb_sales set status = 'cancel' where id = s.id;
  if not exists (select 1 from keiba_entries where horse_id = s.horse_id) then
    delete from keiba_horses where id = s.horse_id;
  else
    delete from kb_care where horse_id = s.horse_id;
    update keiba_horses set barn = false where id = s.horse_id and owner is null;
  end if;
  return hx_admin_state();
end $$;

-- せり場（競市の会社のページ・所持馬から）：ひらいているせり・これから・終わったせり
create or replace function public.hx_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me_g(); co companies := _hx_co();
begin
  perform _kb_sales_tick();
  return jsonb_build_object(
    'now_ms', _kb_ms(_now()), 'balance', _bal(u), 'guest', _is_guest(u),
    'co', case when co.id is not null then jsonb_build_object('cid', co.cid, 'name', co.name, 'status', co.status) end,
    'open', co.id is not null and co.status = 'active',
    'snipe_min', (_kb_own_c()->>'snipe_min')::int,
    'lots', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'horse', _kb_hjson(h), 'info', s.info, 'note', s.note,
               'start', s.start_price, 'buy_now', s.buy_now, 'price', s.price, 'min', _kb_bid_min(s), 'nbids', s.nbids,
               'top_me', s.top = u, 'has_top', s.top is not null, 'own', s.created_by = u,
               'opens_ms', _kb_ms(s.opens_at), 'ends_ms', _kb_ms(s.ends_at), 'status', s.status)
               order by (s.opens_at > _now()), s.ends_at, s.id), '[]'::jsonb)
               from kb_sales s join keiba_horses h on h.id = s.horse_id where s.event and s.status = 'open'),
    'done', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'horse', _kb_hjson(h), 'status', s.status, 'sold_price', s.sold_price,
               'buyer', (select p.nickname from profiles p where p.id = s.buyer), 'won', s.buyer = u,
               'at_ms', _kb_ms(coalesce(s.sold_at, s.ends_at))) order by coalesce(s.sold_at, s.ends_at) desc), '[]'::jsonb)
               from (select * from kb_sales where event and status in ('sold', 'unsold') order by coalesce(sold_at, ends_at) desc limit 12) s
               join keiba_horses h on h.id = s.horse_id));
end $$;

-- 落札・即決のあと：馬をわたす・代金は競市の会社に（代金は、もうあずかっている）
create or replace function public._hx_sold(s public.kb_sales, who uuid, amt bigint, how text) returns void
language plpgsql set search_path = public as $$
declare nm text;
begin
  select name into nm from keiba_horses where id = s.horse_id;
  update kb_sales set status = 'sold', buyer = who, sold_price = amt, sold_at = _now(), price = amt, top = who where id = s.id;
  perform _log(who, 'owner', amt, 0, jsonb_build_object('buy', s.horse_id, 'sale', s.id, 'kind', how, 'title', format('「%s」を落札', nm)));
  perform _hx_paid(who, amt, 'horse', format('せり「%s」の落札', nm));
  perform _kb_give_horse(s.horse_id, who);
  update kb_care set bought = amt, feed = case when exists (select 1 from profiles where id = who and ai is not null) then 'good' else feed end
   where horse_id = s.horse_id;
  perform _notice(who, format('【せり】「%s」を %s X で落札しました。あなたの馬です（メイン → 所持馬）。', nm, _fmt(amt)));
end $$;

-- 値をつける（つけた値はあずかる。上回られたら返す。終わる5分前からは、値がつくたびに5分のびる）
create or replace function public._hx_bid(s public.kb_sales, u uuid, p_amount bigint) returns void
language plpgsql set search_path = public as $$
declare mn bigint; nm text;
begin
  if s.status <> 'open' or _now() >= s.ends_at then raise exception 'この馬のせりは終わりました'; end if;
  if _now() < s.opens_at then raise exception 'せりは % からです', to_char(s.opens_at at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'); end if;
  if s.created_by = u then raise exception '自分が出品した馬には値をつけられません'; end if;
  if s.top = u then raise exception 'いちばん高い値をつけているのは、あなたです'; end if;
  mn := _kb_bid_min(s);
  if p_amount is null or p_amount < mn then raise exception '% X 以上の値をつけてください', _fmt(mn); end if;
  if p_amount > 1000000000 then raise exception '値が大きすぎます'; end if;
  select name into nm from keiba_horses where id = s.horse_id;
  perform _take(u, p_amount);
  perform _log(u, 'owner_hold', p_amount, 0, jsonb_build_object('sale', s.id, 'horse', s.horse_id, 'title', format('「%s」に値をつけた', nm)));
  if s.top is not null then
    perform _give(s.top, s.price);
    perform _log(s.top, 'owner_back', 0, s.price, jsonb_build_object('sale', s.id, 'horse', s.horse_id, 'title', format('「%s」で上回られた', nm)));
    perform _notice(s.top, format('【せり】「%s」に、ほかの人がもっと高い値（%s X）をつけました。あずけていた %s X は返しました。', nm, _fmt(p_amount), _fmt(s.price)));
  end if;
  update kb_sales set price = p_amount, top = u, nbids = nbids + 1,
         ends_at = greatest(ends_at, _now() + make_interval(mins => (_kb_own_c()->>'snipe_min')::int)) where id = s.id;
  insert into kb_bids(sale_id, user_id, amount, at) values (s.id, u, p_amount, _now());
end $$;

-- 即決（その値で、すぐ落札）
create or replace function public._hx_buynow(s public.kb_sales, u uuid) returns void
language plpgsql set search_path = public as $$
declare nm text;
begin
  if s.buy_now is null then raise exception 'この馬に即決の値はありません'; end if;
  if s.status <> 'open' or _now() >= s.ends_at then raise exception 'この馬のせりは終わりました'; end if;
  if _now() < s.opens_at then raise exception 'せりは % からです', to_char(s.opens_at at time zone 'Asia/Tokyo', 'FMMM"月"FMDD"日" HH24:MI'); end if;
  if s.created_by = u then raise exception '自分が出品した馬は買えません'; end if;
  select name into nm from keiba_horses where id = s.horse_id;
  perform _take(u, s.buy_now);
  if s.top is not null then
    perform _give(s.top, s.price);
    perform _log(s.top, 'owner_back', 0, s.price, jsonb_build_object('sale', s.id, 'horse', s.horse_id, 'title', format('「%s」で即決された', nm)));
    if s.top <> u then
      perform _notice(s.top, format('【せり】「%s」は、ほかの人が即決（%s X）で買いました。あずけていた %s X は返しました。', nm, _fmt(s.buy_now), _fmt(s.price)));
    end if;
  end if;
  insert into kb_bids(sale_id, user_id, amount, at) values (s.id, u, s.buy_now, _now());
  update kb_sales set nbids = nbids + 1 where id = s.id;
  perform _hx_sold(s, u, s.buy_now, 'buynow');
end $$;

create or replace function public.hx_bid(p_sale bigint, p_amount bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); s kb_sales; co companies := _hx_co();
begin
  if _is_guest(u) then raise exception 'ゲストは、せりに参加できません（本登録すると参加できます）'; end if;
  perform _kb_sales_tick();
  if co.id is null or co.status <> 'active' then raise exception 'せりはいま営業していません'; end if;
  select * into s from kb_sales where id = p_sale for update;
  if not found or not s.event then raise exception 'せりの馬が見つかりません'; end if;
  if s.buy_now is not null and p_amount >= s.buy_now then
    perform _hx_buynow(s, u);
  else
    perform _hx_bid(s, u, p_amount);
  end if;
  return hx_state();
end $$;
create or replace function public.hx_buynow(p_sale bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); s kb_sales; co companies := _hx_co();
begin
  if _is_guest(u) then raise exception 'ゲストは、せりに参加できません（本登録すると参加できます）'; end if;
  perform _kb_sales_tick();
  if co.id is null or co.status <> 'active' then raise exception 'せりはいま営業していません'; end if;
  select * into s from kb_sales where id = p_sale for update;
  if not found or not s.event then raise exception 'せりの馬が見つかりません'; end if;
  perform _hx_buynow(s, u);
  return hx_state();
end $$;

-- AI投資家：見立て（せりごと・AIごとにちがう。いい馬ほど高い。年をとった馬は安い）
create or replace function public._hx_ai_val(s public.kb_sales, ai text) returns bigint
language plpgsql stable set search_path = public as $$
declare k kb_care; h keiba_horses; q numeric; r numeric; age int;
begin
  select * into k from kb_care where horse_id = s.horse_id;
  if not found then return 0; end if;
  select * into h from keiba_horses where id = s.horse_id;
  age := _kb_midx(_now()) - h.born;
  q := _hc_avg(k) * 0.6 + k.pot * 0.4 - greatest(0, age - 4) * 4 + h.class * 2;
  r := 0.5 + (abs(hashtext(s.id::text || ':' || ai)) % 1000) / 1000.0 * 0.8;   -- 0.5〜1.3
  return least(500000000, (800 * power(1.13, (q - 45)) * r))::bigint;
end $$;
-- AI投資家が値をつける（毎分。終わりが近いほどよく動く。見立てより高ければ降りる）
create or replace function public._hx_ai_tick() returns void
language plpgsql set search_path = public as $$
declare s kb_sales; a record; v bigint; mn bigint; left_s numeric; p numeric; amt bigint; co companies := _hx_co();
begin
  if co.id is null or co.status <> 'active' then return; end if;
  for s in select * from kb_sales where event and status = 'open' and opens_at <= _now() and ends_at > _now() order by id for update skip locked loop
    left_s := extract(epoch from (s.ends_at - _now()));
    p := case when left_s < 600 then 0.25 when left_s < 3600 then 0.1 else 0.03 end;
    continue when random() >= p;
    if s.top is not null and exists (select 1 from profiles where id = s.top and ai is not null) and random() < 0.85 then continue; end if;
    mn := _kb_bid_min(s);
    for a in select p2.id, p2.ai, p2.balance from profiles p2 where p2.ai like 'inv%' and p2.id is distinct from s.top order by random() loop
      v := _hx_ai_val(s, a.ai);
      begin
        if s.buy_now is not null and v >= s.buy_now and a.balance >= s.buy_now * 3 and random() < 0.3 then
          perform _hx_buynow(s, a.id);
          exit;
        end if;
        if v >= mn and a.balance >= mn * 3 then
          amt := least(v, mn + (floor(random() * 3) * greatest(50, mn / 20))::bigint);
          if s.buy_now is not null then amt := least(amt, s.buy_now - 1); end if;
          if amt >= mn then perform _hx_bid(s, a.id, amt); end if;
          exit;
        end if;
      exception when others then
        raise warning 'hx ai bid: %', sqlerrm;
        exit;
      end;
    end loop;
  end loop;
end $$;

-- 所持馬：調教（1日1回）
create or replace function public.hc_train(p_horse int, p_menu text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses; k kb_care; m jsonb := _hc_c()->'menus'->p_menu; res text;
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse for update;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  perform _hc_ensure(h.id);
  select * into k from kb_care where horse_id = h.id;
  if k.dead_at is not null then raise exception 'この馬は、もういません'; end if;
  if h.retired then raise exception '引退した馬は調教できません'; end if;
  if m is null then raise exception '調教のメニューをえらんでください'; end if;
  if k.ill is not null and p_menu <> 'rest' then raise exception '病気・けがのあいだは、休養だけできます'; end if;
  if k.trained_on = _kb_jday(_now()) then raise exception '調教は1日1回です（0時に新しくなります）'; end if;
  if exists (select 1 from keiba_entries e join keiba_races r on r.id = e.race_id
              where e.horse_id = h.id and not r.settled and r.post <= _now() + interval '1 hour') then
    raise exception '出走の1時間前から、レースが終わるまでは調教できません';
  end if;
  if not _hc_pay(u, h.id, (m->>'fee')::bigint, format('調教代（%s・%s）', h.name, m->>'name')) then
    raise exception 'AiliNaXが足りません（% X）', _fmt((m->>'fee')::bigint);
  end if;
  res := _hc_do_train(h.id, p_menu);
  return owner_state() || jsonb_build_object('trained', jsonb_build_object('horse', h.id, 'menu', p_menu, 'hurt', res,
                                              'after', _hc_json(h.id), 'before', _hc_json_stats(k)));
end $$;
-- 所持馬：エサ
create or replace function public.hc_feed(p_horse int, p_feed text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses;
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  if p_feed is null or p_feed not in ('normal', 'good', 'best') then raise exception 'エサをえらんでください'; end if;
  perform _hc_ensure(h.id);
  update kb_care set feed = p_feed where horse_id = h.id and dead_at is null;
  return owner_state();
end $$;
-- 所持馬：出走の方針（おまかせ・登録したレースだけ・休ませる）
create or replace function public.hc_mode(p_horse int, p_mode text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses;
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse for update;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  if p_mode is null or p_mode not in ('auto', 'reg', 'rest') then raise exception '出走の方針をえらんでください'; end if;
  perform _hc_ensure(h.id);
  update kb_care set mode = p_mode where horse_id = h.id and dead_at is null;
  if p_mode = 'rest' then delete from kb_regs where horse_id = h.id; end if;
  perform _hc_apply(h.id);
  return owner_state();
end $$;
-- 所持馬：獣医にみせる（治るまでの日数が半分。重い病気でも死ななくなる）
create or replace function public.hc_vet(p_horse int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses; k kb_care; i jsonb; today date := _kb_jday(_now());
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  select * into k from kb_care where horse_id = h.id for update;
  if not found or k.ill is null then raise exception 'この馬は病気・けがをしていません'; end if;
  if k.ill_treated then raise exception 'もう獣医にみせています'; end if;
  i := _hc_c()->'ills'->k.ill;
  if not _hc_pay(u, h.id, (i->>'vet')::bigint, format('獣医代（%s・%s）', h.name, i->>'name')) then
    raise exception 'AiliNaXが足りません（% X）', _fmt((i->>'vet')::bigint);
  end if;
  update kb_care set ill_treated = true, ill_until = greatest(today + 1, today + ceil((ill_until - today) / 2.0)::int) where horse_id = h.id;
  return owner_state();
end $$;
-- 所持馬：引退した馬・死んだ馬を手放す（牧場にあずける・思い出から消す）
create or replace function public.hc_release(p_horse int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := _me(); h keiba_horses;
begin
  perform _kb_own_open(u);
  select * into h from keiba_horses where id = p_horse for update;
  if not found or h.owner is distinct from u then raise exception 'あなたの馬ではありません'; end if;
  if not h.retired then raise exception '手放せるのは、引退した馬だけです（走れる馬は「売りに出す」か「引退」）'; end if;
  perform _kb_release(h.id);
  return owner_state();
end $$;

-- 毎分：育成の時計（せりのAI・レースのあと・毎月・毎朝）
create or replace function public._hc_tick() returns void
language plpgsql set search_path = public as $$
begin
  begin perform _hx_ai_tick(); exception when others then raise warning 'hx ai: %', sqlerrm; end;
  begin perform _hc_after_races(); exception when others then raise warning 'hc races: %', sqlerrm; end;
  begin perform _hc_monthly(); exception when others then raise warning 'hc monthly: %', sqlerrm; end;
  begin perform _hc_daily(); exception when others then raise warning 'hc daily: %', sqlerrm; end;
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
            '_tax','_income','_notice','_debt','_pay_tax','_process_month','_tax_tick','_tax_badge','_assets','_ok7',
            'tax_state','tax_file','tax_pay','_new_acct','_cfull','_cid_norm','_new_ccode','_xfer_fee','_ctax','_xfer_check','transfer_preview','transfer_send','work_state','work_start','work_submit','info_state',
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
            '_oc_col','_oc_sym','_oc_pts','_oc_hand','_oc_arr','_oc_top','_oc_ok','_oc_legal','_oc_next','_oc_log','_oc_draw','_oc_init',
            '_oc_turn','_oc_act','_oc_final','_oc_pending','_oc_cpu','_oc_view',
            '_mj_ids','_mj_cnt','_mj_yao','_mj_kokushi','_mj_sets_ok','_mj_agari','_mj_waits','_mj_sh_part','_mj_part','_mj_shanten',
            '_mj_dec_sets','_mj_decomp','_mj_dora_of','_mj_kname','_mj_base','_mj_c100','_mj_score','_mj_pay','_mj_label',
            '_mj_log','_mj_hand','_mj_set','_mj_sorted','_mj_nm','_mj_open','_mj_wall_n','_mj_seatw','_mj_has','_mj_can_after','_mj_kuikae_chi',
            '_mj_variants','_mj_ctx','_mj_try','_mj_furiten','_mj_actopts','_mj_draw','_mj_deal','_mj_init','_mj_final','_mj_end','_mj_abort',
            '_mj_ryukyoku','_mj_win','_mj_over','_mj_next_hand','_mj_after','_mj_call','_mj_resolve','_mj_discard','_mj_selfkan',
            '_mj_pending','_mj_delay','_mj_act','_mj_view','_mj_tval','_mj_safe','_mj_seen','_mj_sh_after','_mj_cpu',
            '_au_step','_au_min','_au_lot','_au_init','_au_plan','_au_next','_au_bid','_au_close','_au_act','_au_final','_au_view','_au_hold','_au_money','_au_abort','_au_cron',
            '_kk_ids','_kk_sort','_kk_kind','_kk_yaku','_kk_pts','_kk_teshi','_kk_log','_kk_add','_kk_final','_kk_end','_kk_deal','_kk_init',
            '_kk_next','_kk_put','_kk_pass','_kk_win','_kk_after','_kk_draw','_kk_act','_kk_pending','_kk_delay','_kk_val','_kk_need_set','_kk_need','_kk_gain','_kk_cpu','_kk_view',
            '_is_multi','_mg_init','_mg_pending','_mg_act','_mg_cpu','_mg_view','_mg_delay','_mg_final','_room_cancel','_room_refund','_room_stake',
            '_mroom_hum','_mroom_start','_mroom_settle','_mroom_tick','_mroom_move','room_start','room_quit',
            '_notice_l','notice_list','notice_count','notice_read_all','_mention_ids','_mention_names','_mention_notify',
            '_person_card','people_search','person_page','pub_delete','admin_corp_cert','_week_start','_corp_rating','_corp_involved','review_state','review_submit',
            '_pub_mine','_pub_can_read','_pub_json','pub_list','news_list','pub_page','pub_read','pub_buy','pub_save','pub_item_save',
            'pub_item_delete','my_pubs','admin_pub_hide',
            '_kb_norm','_kb_gumbel','_kb_midx','_kb_jday','_kb_ms','_kb_agef','_kb_fit','_kb_name','_kb_new_horse',
            '_kb_make_race','_kb_make_day','_kb_make_night','_kb_make_noon','_kb_seq','_kb_prob','_kb_prob_trio','_kb_rate','_kb_odds','_kb_check_sel',
            '_kb_hit','_kb_settle','_kb_month','_kb_seed','_kb_tick','_kb_status','_kb_scratch','_kb_margin',
            '_ind_norm','corp_set_industries','_srv_norm','corp_set_servers','admin_corp_servers_clear',
            '_desk_staff','_desk_json','_desk_people','_desk_unread','desk_thread','desk_open','desk_send','desk_close','desk_list',
            'desk_settings','corp_member_desk','_user_row','admin_users','admin_user',
            '_holdings','_stock_exch','_stock_market','_stock_list','_stock_cancel_order','_stock_delist','stock_list','stock_state',
            '_stock_width','_jday_start','_stock_base','_stock_band','_stock_day','_tnow','info_today','_stock_exec','stock_chart','home_widgets',
            '_ai_uid','_randn','_ai_name','_ai_account','_ai_fund','_ai_hire','_ai_ceo','_ai_stock_value','_ai_fair','_ai_article','_ai_event',
            '_ai_business','_ai_settle_week','_ai_news_morning','_ai_news_items','_ai_news_flash','_ai_invest','_ai_market','_ai_market_cancel',
            '_ai_setup','_ai_add_investors','_ai_tick','_fx_exec','_stock_width_x','_ai_buzz_target','_ai_fair_p','_ai_found','_ok7_ins','_stock_last','_stock_cancel_all','stock_split','admin_stock_reprice','admin_gov_share_give','admin_ai_news','_gov_uid','_gov_sweep','_fx_last','admin_iv_state','admin_intervene','_ai_err','admin_ai','admin_ai_set','admin_ai_fund',
            'stock_order','stock_cancel','stock_list_apply','stock_list_withdraw','admin_stock_decide','admin_stock_delist','_unlock_orders',
            '_kb_wx','admin_kb_extras','admin_kb_extra','admin_kb_extra_cancel','banner_list','admin_banners','admin_banner_save','admin_banner_end',
            'prefs_save','_admin_ids','_msg_unread','_is_guest','_me_g','_is_event','_staff_list','admin_staff','admin_staff_set',
            '_guest_last','_guest_until','_guest_sent5','_guest_json','guest_extend','_guest_send_check','_guest_verify','_guest_cap_trg','_sink_user','_guest_flush',
            '_guest_purge','_req_ip','guest_signup','guest_set_email',
            '_bt_tok','_bt_auth','_bt_row','_bt_create','_bt_start','_bt_settle','_bt_cron','bt_ticket','bt_list','bt_state','bt_join','bt_leave',
            'bt_lobby_set','bt_bet','bt_react',
            '_lot_seed','_lot_prize','_lot_tier_name','_rnd','_lot_next_at','_lot_tick','_lot_draw','lot_buy','lot_state','dm_list','dm_thread','dm_send','_sp_json','support_list','support_thread','support_open','support_send','support_close',
            'keiba_day','keiba_race','keiba_odds','keiba_bet','keiba_horse',
            'money_history','corp_ledger_page','_kb_bid_min','_kb_can_run','_kb_colors','_kb_give_horse','_kb_hint','_kb_hjson','_kb_own_c','_kb_own_open','_kb_own_tick','_kb_owned_n','_kb_owner_row','_kb_prog_day','_kb_release','_kb_sale_at','_kb_sale_day','_kb_sales_tick','_kb_take_regs','_kb_upkeep_tick','owner_bid','owner_buy','owner_name','owner_reg','owner_retire','owner_sell','owner_silks','owner_state',
            'fi_cast','fi_consign','fi_hook','fi_join','fi_land','fi_state',
            '_pr_bonus','_pr_check_sel','_pr_hit','_pr_make_day','_pr_make_race','_pr_margin','_pr_month','_pr_name','_pr_new_racer','_pr_odds','_pr_open','_pr_prob','_pr_rate','_pr_seed','_pr_settle','_pr_status','_pr_tick','_pr_wx','pr_bet','pr_day','pr_odds','pr_race','pr_racer',
            '_gt_today','_gt_kinds','_gt_pool','_gt_label','_gt_ensure','_gt_xpb','_gt_need','_gt_lv','_gt_titles','_gt_title','_gt_tiers','_gt_tier','_gt_tname',
            '_gt_cpts','_gt_badge','_gt_add_xp','_gt_casino','_gt_pay','_gt_settle','_gt_event0','_gt_event','_gt_tx_trg','_gt_buy_trg','_gt_room_trg',
            '_gt_brief','_gt_board','game_tasks',
            '_self_shares','_corp_parent','_corp_subs','_corp_hold_uid','_corp_hold_money','corp_share_offer',
            '_corp_owned','_corp_max',
            '_hc_c','_hx_co','_hx_paid','_hc_grade','_hc_avg','_hc_json_stats','_hc_apply','_hc_ensure','_hc_can_run','_hc_sick','_hc_die',
            '_hc_pay','_hc_do_train','_hc_daily','_hc_monthly','_hc_after_races','_hc_json','_hx_info','hx_admin_state','hx_admin_create',
            'hx_admin_cancel','hx_state','_hx_sold','_hx_bid','_hx_buynow','hx_bid','hx_buynow','_hx_ai_val','_hx_ai_tick',
            'hc_train','hc_feed','hc_mode','hc_vet','hc_release','_hc_tick') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if left(f.proname, 1) = '_' then
      execute format('revoke all on function %s from authenticated', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
-- 念のため：一覧に入れわすれた関数も、だれでも（ログインなし）は呼べない。_ ではじまるものはログインしても呼べない
do $$
declare
  f record;
begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if left(f.proname, 1) = '_' then execute format('revoke all on function %s from authenticated', f.sig); end if;
  end loop;
end $$;
-- ゲストをはじめるのは、ログインの前（だれでも）
grant execute on function public.guest_signup(text, text) to anon, authenticated;
