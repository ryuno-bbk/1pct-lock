-- ============================================================
-- 075: 公式マーク (users.is_official) + 公式アカウントの言語出し分け (users.lang_exclusive)
--
-- 背景:
--   ① フィード4関数が UGC 投稿について `false AS is_official_author` をハードコードしており、
--      運営アカウント (ai_motivation) に認証バッジを出せない。public.users に列が無かった。
--   ② 073 の同一言語ボーナス (w_same_lang) は重み 0.0 で出荷され、フィードは言語を見ていない。
--      公式アカウントが同内容の日本語版/英語版を2投稿したとき、両方が全員に出てしまう。
--
-- 方針:
--   一般ユーザーの見え方は一切変えない。lang_exclusive を立てたアカウント (= 公式) だけが
--   言語で振り分けられる。既定値はどちらも false なので、既存の全ユーザーは現状維持。
--
-- ⚠️ この STEP 1 だけでは挙動は何も変わらない (列を足して自己昇格を塞ぐだけ)。
--    フィード関数の書き換えは STEP 2 以降。
-- ============================================================

begin;

-- ------------------------------------------------------------
-- STEP 1-a: 列を追加
-- ------------------------------------------------------------
-- is_official    : 認証バッジ。FeedListCard.nameLabel(official:) がチェックマークを描く
-- lang_exclusive : true のアカウントの投稿は「閲覧者の言語に合う1本」だけをフィードに出す
alter table public.users add column if not exists is_official    boolean not null default false;
alter table public.users add column if not exists lang_exclusive boolean not null default false;

comment on column public.users.is_official is
    '運営の公式アカウント。フィードで認証バッジを出す。ユーザーは自分で変更できない (users_protect_is_pro トリガで拒否)';
comment on column public.users.lang_exclusive is
    'true のとき、このアカウントの投稿は閲覧者の言語 (users.lang) に一致するものだけをフィードに出す。'
    'lang が NULL の投稿は言語を問わない扱いで全員に出る。既定 false = 従来どおり全員に出る';

-- ------------------------------------------------------------
-- STEP 1-b: 自己昇格の防止
-- ------------------------------------------------------------
-- 🔴 public.users の RLS は users_update_own (auth.uid() = id) で「自分の行の全列」を
--    更新できてしまう (列単位の GRANT も制限されていない)。このまま列を足すと、
--    任意のユーザーが PATCH /users?id=eq.<自分> {"is_official": true} で
--    認証バッジを自分に付けられる。is_pro と同じ流儀で BEFORE UPDATE トリガに追加して塞ぐ。
--    rolbypassrls (postgres / service_role) は従来どおり素通し = 運営の SQL / スタジオは書ける。
create or replace function public.protect_users_is_pro()
returns trigger
language plpgsql
as $function$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND rolbypassrls
    ) THEN
        RETURN NEW;
    END IF;
    IF NEW.is_pro IS DISTINCT FROM OLD.is_pro THEN
        RAISE EXCEPTION 'is_pro is read-only for users';
    END IF;
    IF NEW.rc_last_event_ms IS DISTINCT FROM OLD.rc_last_event_ms THEN
        RAISE EXCEPTION 'rc_last_event_ms is read-only for users';
    END IF;
    -- 075: 認証バッジ / 言語出し分けの自己設定を禁止
    IF NEW.is_official IS DISTINCT FROM OLD.is_official THEN
        RAISE EXCEPTION 'is_official is read-only for users';
    END IF;
    IF NEW.lang_exclusive IS DISTINCT FROM OLD.lang_exclusive THEN
        RAISE EXCEPTION 'lang_exclusive is read-only for users';
    END IF;
    RETURN NEW;
END;
$function$;

commit;
