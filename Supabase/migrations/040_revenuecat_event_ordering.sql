-- ============================================================
-- 040_revenuecat_event_ordering.sql
-- 監査 L24: RevenueCat webhookイベントの順序保証 (rc_last_event_ms)
-- ============================================================
-- 背景: RevenueCatのwebhookは順序保証がない。DB障害時のリトライで、
-- 遅延到着した古いEXPIRATIONが、その後に処理された新しいINITIAL_PURCHASEの
-- is_pro=trueを誤って上書きするシーケンスが起こりうる。
-- event_timestamp_msの単調性をDB側でガードすることで解決する。

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS rc_last_event_ms bigint;

COMMENT ON COLUMN public.users.rc_last_event_ms IS
    'RevenueCat webhookで最後に反映したevent.event_timestamp_ms。古いイベントの巻き戻り防止用';

-- is_pro を event_timestamp_ms の単調性を守りながら更新するSECURITY DEFINER関数。
-- 015のprotect_users_is_proトリガーはservice_role/postgresのrolbypassrlsを通すので、
-- この関数もpostgres所有のSECURITY DEFINERとして同様に通過する。
-- p_event_ms が NULL の場合はガード無しで従来通り更新する (イベントにタイムスタンプが無いケースへのフォールバック)。
CREATE OR REPLACE FUNCTION public.set_is_pro_guarded(
    p_user_id  uuid,
    p_is_pro   boolean,
    p_event_ms bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_updated boolean;
BEGIN
    UPDATE public.users
    SET is_pro = p_is_pro,
        rc_last_event_ms = COALESCE(p_event_ms, rc_last_event_ms)
    WHERE id = p_user_id
      AND (
        p_event_ms IS NULL
        OR rc_last_event_ms IS NULL
        OR rc_last_event_ms < p_event_ms
      )
    RETURNING true INTO v_updated;

    RETURN COALESCE(v_updated, false);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_is_pro_guarded(uuid, boolean, bigint) FROM PUBLIC, anon, authenticated;
-- この関数は Edge Function が PostgREST /rpc 経由で service_role として直接呼ぶ。
-- create_notification のような「postgres 所有の SECURITY DEFINER 内部からの呼び出し」と
-- 違い、EXECUTE 権限チェックが service_role 自身に掛かる (rolbypassrls が素通りさせる
-- のは RLS のみで、関数 ACL は対象外)。Supabase の default privileges に依存せず明示 GRANT
GRANT EXECUTE ON FUNCTION public.set_is_pro_guarded(uuid, boolean, bigint) TO service_role;

-- ============================================================
-- rc_last_event_ms の列レベル保護 (レビューで発見、L24修正自身が生みかけた抜け穴)
-- ============================================================
-- users_update_own ポリシー (003_a_rls_rpc.sql:70-73) は auth.uid()=id の行全体
-- UPDATE を許可しており列単位の制限が無い。rc_last_event_ms を無防備のままにすると、
-- 認証済みユーザーが自分のJWTで直接この列に未来の巨大値を書き込め、
-- set_is_pro_guarded の単調性ガード (rc_last_event_ms < p_event_ms) が以後届く
-- 本物のRevenueCatイベント全てに対して永久に不成立になる。結果、実際にサブスクが
-- 失効しても EXPIRATION が無視され is_pro=true が恒久固定される
-- (H12 と同種の課金バイパスを、この L24 修正自身が新設してしまうところだった)。
-- is_pro と同じ trigger (015 protect_users_is_pro) で一緒に守ることで解決する。
-- トリガー本体 (015 で定義済みの users_protect_is_pro, BEFORE UPDATE) はそのまま
-- 流用され、関数の CREATE OR REPLACE だけで新しい列も保護対象になる。
CREATE OR REPLACE FUNCTION public.protect_users_is_pro()
RETURNS trigger
LANGUAGE plpgsql
AS $$
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
    RETURN NEW;
END;
$$;
