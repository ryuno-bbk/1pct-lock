-- ============================================================
-- 077: relax the upper limit of user_posts.image_count from 4 → 5
--
-- Reason: the official account's "If you can't run → walk → if you can't walk → crawl if you have to →
--       just keep moving forward" is one story in 5 frames. Cutting it to 4 images breaks the story,
--       and splitting it into 5 posts breaks the order because of author_cap=2 and score order, so it
--       makes no sense.
--
-- No app resubmission needed:
--   FeedItem.imageUrls is built generically with (1...count) and has no upper limit.
--   FeedListCard's carousel with ForEach(item.imageUrls) / page dots with
--   ForEach(0..<item.imageCount) are also generic. The shipped 1.0.3 can draw 5 images as is.
--   Hidden pages load only ±1 (M19 fix), so egress does not grow either.
--
-- No effect on regular users:
--   The app's post UI (PostFlowView) limits posts to 4 images on the client side, so
--   real users' posts never have 5 images. It only matters when the operator inserts via SQL.
--
-- To revert (delete the 5-image posts first):
--   alter table public.user_posts drop constraint user_posts_image_count_range;
--   alter table public.user_posts add constraint user_posts_image_count_range
--     check (image_count >= 1 and image_count <= 4);
-- ============================================================

alter table public.user_posts drop constraint user_posts_image_count_range;
alter table public.user_posts add constraint user_posts_image_count_range
    check (image_count >= 1 and image_count <= 5);
