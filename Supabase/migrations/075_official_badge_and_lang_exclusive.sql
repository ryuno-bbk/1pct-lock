-- ============================================================
-- 075: official badge (users.is_official) + per-language delivery for the official account
-- (users.lang_exclusive)
--
-- Background:
--   ① The 4 feed functions hardcode `false AS is_official_author` for UGC posts, so the operator
--      account (ai_motivation) cannot show a verified badge. public.users had no column for it.
--   ② The same-language bonus of 073 (w_same_lang) shipped with weight 0.0, and the feed does not
--      look at language. When the official account posts the same content twice, as a Japanese and
--      an English version, both are shown to everyone.
--
-- Policy:
--   Nothing changes in what regular users see. Only accounts with lang_exclusive set (= official) are
--   routed by language. Both default to false, so all existing users stay as they are.
--
-- ⚠️ This STEP 1 alone changes no behavior (it only adds columns and closes self-promotion).
--    Rewriting the feed functions is STEP 2 onward.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- STEP 1-a: add columns
-- ------------------------------------------------------------
-- is_official    : verified badge. FeedListCard.nameLabel(official:) draws the check mark
-- lang_exclusive : for accounts with true, only "the one post that matches the viewer's language" is
--                  shown in the feed
alter table public.users add column if not exists is_official    boolean not null default false;
alter table public.users add column if not exists lang_exclusive boolean not null default false;

comment on column public.users.is_official is
    '運営の公式アカウント。フィードで認証バッジを出す。ユーザーは自分で変更できない (users_protect_is_pro トリガで拒否)';
comment on column public.users.lang_exclusive is
    'true のとき、このアカウントの投稿は閲覧者の言語 (users.lang) に一致するものだけをフィードに出す。'
    'lang が NULL の投稿は言語を問わない扱いで全員に出る。既定 false = 従来どおり全員に出る';

-- ------------------------------------------------------------
-- STEP 1-b: prevent self-promotion
-- ------------------------------------------------------------
-- 🔴 The RLS of public.users, users_update_own (auth.uid() = id), allows updating "all columns of your
--    own row" (column-level GRANTs are not restricted either). If we just add the columns, any user can
--    give themself the verified badge with PATCH /users?id=eq.<me> {"is_official": true}.
--    Close it by adding it to the BEFORE UPDATE trigger, the same way as is_pro.
--    rolbypassrls (postgres / service_role) passes through as before = the operator's SQL / studio can
--    still write.
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
    -- 075: forbid setting the verified badge / per-language delivery on yourself
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
