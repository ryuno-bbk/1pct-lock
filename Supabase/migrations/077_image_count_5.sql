-- ============================================================
-- 077: user_posts.image_count の上限を 4 → 5 に緩める
--
-- 理由: 公式アカウントの「走れないなら→歩け→歩けないなら→這ってでも進め→
--       とにかく前に進め」は5コマで1つの物語。4枚に削ると話が壊れ、
--       5投稿に分けると author_cap=2 とスコア順で順番が崩れて意味を成さない。
--
-- アプリ再提出は不要:
--   FeedItem.imageUrls は (1...count) で汎用に組み立てており上限が無い。
--   FeedListCard のカルーセルも ForEach(item.imageUrls) / ページドットも
--   ForEach(0..<item.imageCount) で汎用。出荷済み 1.0.3 が5枚をそのまま描ける。
--   非表示ページは ±1 しかロードしない (M19対策) ので egress も増えない。
--
-- 一般ユーザーへの影響なし:
--   アプリの投稿UI (PostFlowView) がクライアント側で4枚に制限しているため、
--   実ユーザーの投稿が5枚になることはない。運営が SQL で入れる時だけ効く。
--
-- 戻すとき (5枚投稿を先に消してから):
--   alter table public.user_posts drop constraint user_posts_image_count_range;
--   alter table public.user_posts add constraint user_posts_image_count_range
--     check (image_count >= 1 and image_count <= 4);
-- ============================================================

alter table public.user_posts drop constraint user_posts_image_count_range;
alter table public.user_posts add constraint user_posts_image_count_range
    check (image_count >= 1 and image_count <= 5);
