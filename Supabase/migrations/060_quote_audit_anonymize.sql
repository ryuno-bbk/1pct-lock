-- 060_quote_audit_anonymize.sql
-- 名言全件監査の反映 (2026-07-30 ユーザー全件判定: Docs/quote_audit_verdicts_2026_07_30.txt + v2文言編集)
--   1) 削除109件 (実名リスク/重複。quote_likes等はFK CASCADEで自動削除)
--   2) 文言修正20件 (ユーザー添削済み)
--   3) 残存全件を匿名著者 Anonymous (0c606f06) へ付け替え = 実名表示の全廃
--   4) 新規2件 (ユーザー支給)
-- 冪等: 再実行しても安全 (DELETE/UPDATEは自然に冪等、INSERTはON CONFLICT DO NOTHING)
-- ロールバック: 削除の復元はダンプからのみ。適用前にダンプ推奨 (無料枠でもTable Editor→CSV)
BEGIN;

DELETE FROM public.quotes WHERE id IN (
    '48cd8389-a2f9-450f-989f-9ce479e83585',
    '8d591e6c-2724-41cb-8ecd-59902e8bd84d',
    'd6ea12b3-22a1-4412-b538-39d4f5ced2e2',
    'eb54c67b-d270-4a27-a82e-af394183b909',
    '550e8400-e29b-41d4-a716-446655440015',
    '7e53514c-ff5d-4d41-b30a-b407992f149c',
    '086afab9-492d-4448-b413-bed16e2276ef',
    '14ef15e6-0b89-434e-af5c-9512160c0645',
    '43388a96-0dab-4d54-bef7-d4b0e2eac5d9',
    '44e0decb-3557-47df-8fe1-ed1390c4571e',
    '6caceb9e-c4b1-4d43-b9d0-04098fd988c7',
    '94eb06a1-6edd-49de-9140-b0b94111803b',
    'e710d12f-3395-4305-804f-296a3a234061',
    'e9ec18a4-fccf-4bd4-9eef-7f0fe9134703',
    '308af9e2-7f0d-4ca3-8d9e-23e581304e6d',
    '550e8400-e29b-41d4-a716-446655440009',
    '623a0cf9-badb-4cc0-8063-5ef63da19652',
    'cdda0bea-4046-4165-b6fa-6612310028bb',
    'd4221364-14f1-4dd0-b810-0a1d0d686752',
    '7ecd2264-4649-405a-b75e-b009a83fca3a',
    'efca8dd3-138d-476b-a1b5-d1d4a490d6bf',
    '06584f7e-fa4c-4dc5-8464-eb44a3a65923',
    '4ff6cea4-3fe8-484e-82d8-5a046c149164',
    '7291f739-bd3e-47c1-8982-3c03c038b22f',
    'f95f5b9c-ec83-4e9e-b0b6-00f1d11c11a0',
    '024c8112-781b-4b5e-99d9-cf6c18ab796b',
    '07789bee-b00e-4b8e-b99e-ed5e40f47210',
    '14a2d20e-0fbe-4028-9937-efbfab1ef286',
    '48a0ce57-37b6-49df-b87c-3c0f74308899',
    '4a061d39-af11-45f9-b67d-2a104d58f552',
    '2989879c-c74c-41ec-8932-b0dcf445c53e',
    '78e60a32-dad5-416a-9501-921a4c630527',
    'f0a1c300-97de-4ac9-b05f-60064b77c3a1',
    'fd97fc2d-56dc-4dc0-936b-dc4c3db1440b',
    '125e990f-1651-4227-8b41-6e65928a7a1e',
    '6bee3c15-ea4a-4b0b-8298-712d66e659c4',
    'aaf1ffc9-c5d7-4b70-9a01-1d54d32ca7aa',
    'f1ec4722-f4bb-4985-ad3b-1d2580a4c58d',
    '2c78b17f-d9bf-4324-b185-970f824efeaa',
    '5a51e727-58ff-4130-8044-28d08979ee45',
    '7a5896fd-580e-48d9-be68-3666187693c2',
    'dc7b8281-0572-405a-83bf-047bbc1be920',
    '1d16f81f-f4e4-49b0-9f8f-21cd3e23cbdc',
    '22e0d5fb-a702-4c7e-b2e4-2fe8f43b4039',
    '294814ac-d28c-4864-a124-95de58189957',
    '3eb1ab6a-0842-46ba-992f-3408ada8f76a',
    '58b0cec1-6511-4ed5-8a92-b2b28a889b1a',
    '3ddd08db-8ab4-41dd-8213-0895be36943a',
    '6f9a77d5-31c5-48a3-bf9f-f2e2a9797963',
    '7c791c2d-2b5f-4c29-9c51-8cf0d5afc0ab',
    'b61d5e15-b086-4aec-a286-82d09a33a93f',
    '07057640-fe21-4578-8888-2c3e26d24842',
    '70cd4056-b571-4b21-b423-a34deb758b8b',
    '70f284a2-02d8-4847-9e13-ed8bc6e19609',
    'f640db60-dc50-40c8-b4ab-5674f0195ea7',
    '11f61662-f013-4bb5-9b44-18c5862e4137',
    '4e1baf4b-ebbb-4f30-b857-16174e970134',
    '5ce46d5b-8f8f-4b5a-a351-54458efe685d',
    '5fa714b9-6d26-4c4e-be22-d6fb174131ad',
    'f8858624-6264-4019-a20a-b642094a0cda',
    '2f4a694b-b884-4887-a1f5-06c5e6b1178b',
    '56a2031e-3ca0-418b-aaba-63f6e77a4675',
    'd55c1801-f64a-4a90-afe2-f059bdd834ed',
    '402c5a22-f3b8-4296-bb84-345478bcaa2f',
    '4f8b8c11-b324-44f4-85e1-59a0b0865ac2',
    '72f8d992-aa13-4254-81ba-336088d16403',
    '75e1097b-cc1b-4fb8-ad45-bc38de3a35d0',
    '8ca0604c-5f65-4f4c-9f8c-a38c62a0e4ab',
    '49f911c1-3b55-4450-b9b6-3183a50aa8af',
    'a381dc9b-a87a-4dfc-a0c2-114aed1e4c4e',
    'c9177f64-3828-4241-87db-f17a7d2f03d1',
    'e8e1e54e-7ccc-48ce-b2b6-a7da8099b9a5',
    '7955b724-b0fc-4322-9044-c110aef8e51e',
    'b0d0c506-68aa-4ace-9d5e-09727a170465',
    'e62e04c9-ce41-4d7c-a8e1-7cc870c18b3d',
    '8865a640-89e6-4f73-a7da-357907649571',
    'a5ebc72f-81ec-4144-9569-21594a378635',
    '3851b810-c39b-45eb-b253-994a09a19e65',
    '568e3f7a-0c94-44b6-8f17-e23e6330c55a',
    '7ec271f9-79f5-4bd3-ad7e-eecceba87477',
    'ad60026c-c5cf-4467-afb6-50adae9577b9',
    'aa10a98a-9089-4ccb-9f66-b07c1b9672d1',
    'f4a751c7-8780-42e5-802e-bdd1336521a5',
    '550e8400-e29b-41d4-a716-446655440012',
    'cc411d75-a192-4d34-a456-0ac473c145a1',
    'e93c810e-0063-4450-b41b-0e8943809d75',
    '35bda961-efa4-4aea-87c3-dba081b43ab3',
    '550e8400-e29b-41d4-a716-446655440007',
    '3af41afe-a554-409f-8856-003c4b7a39d7',
    '4afcac16-07a8-4c03-b7df-df94c3c502d9',
    'b503dbaa-9996-4a13-ad29-9900a2feecf7',
    'ea874e78-6a6e-4529-bab3-adce70ab10c2',
    'f1d3d48e-f59e-4594-9de5-3cc8de981ee9',
    '827172d6-33bf-4652-a699-5baadd1dff7a',
    '9c835163-f48d-4be2-98f4-1aa96447741b',
    '550e8400-e29b-41d4-a716-446655440003',
    '550e8400-e29b-41d4-a716-446655440006',
    '550e8400-e29b-41d4-a716-446655440014',
    '9d9b9d54-9698-4995-b5b8-59c98893bc79',
    '550e8400-e29b-41d4-a716-446655440020',
    '550e8400-e29b-41d4-a716-446655440011',
    '550e8400-e29b-41d4-a716-446655440013',
    '1bc9add9-0ae7-4d81-a514-148ddb126c0b',
    '550e8400-e29b-41d4-a716-446655440008',
    '740e374c-3c84-4fb9-ab2b-48cf20091086',
    'a8fd2d38-4c0a-48bc-a361-efe1b7c0c0e1',
    '5e73ac88-f9f4-4301-93f6-ba60196c4ece',
    '6fb91d5e-1b90-4f6d-9020-d73fbcf62ec8',
    '550e8400-e29b-41d4-a716-446655440019'
);

UPDATE public.quotes SET text_jp = '失敗しても後悔しないと分かっていた。後悔することがあるとするならば、それは挑戦しないことだとも分かっていた。', text_en = 'I knew that if I failed I wouldn''t regret that. But I knew the one thing I might regret is not trying.' WHERE id = '08e8a8a6-f9c0-46fd-931f-02208d00c297';
UPDATE public.quotes SET text_jp = 'お前が探している夢を叶える魔法は、お前が避けている作業の中にある。', text_en = 'The magic you''re looking for is in the work you''re avoiding.' WHERE id = '0d071cf7-2704-48d2-9fac-50e3736fb9f2';
UPDATE public.quotes SET text_jp = '何かを始めるのに最初から優れている必要はない。ただ、優れた人になるにはまず始めなければならない。', text_en = 'You don''t have to be great to get started, but you have to get started to be great.' WHERE id = '19d2a16a-5041-4cf6-8370-66c6f76c364b';
UPDATE public.quotes SET text_jp = '唯一の達成不可能な目標は、始めない目標だ。', text_en = 'The only impossible journey is the one you never begin.' WHERE id = '227c491c-9405-4d8d-950b-95feebfe5af2';
UPDATE public.quotes SET text_jp = '状況が悪くなった時、強いやつから動き出す。', text_en = 'When the going gets tough, the tough get going.' WHERE id = '251aa1a5-f330-4936-b9fb-e57e9c44edf2';
UPDATE public.quotes SET text_jp = '人は何かを始めるには完璧な条件を待つ。でも実際は、始めることこそが条件を完璧にする', text_en = 'People think they need a perfect condition to start, when in reality, starting is the perfect condition.' WHERE id = '256fc2df-51ac-46f6-84b3-d932cf089011';
UPDATE public.quotes SET text_jp = '辛い日々こそが、いつか自分が何を乗り越えてきたかという「物語」を作ってくれるんだ。辛い日々がなければ、その物語はもっとずっとダサいものになってしまう。', text_en = 'The bad days create the story that I''m one day going to tell myself about what I got through. Without the bad days, the story would be way more lame.' WHERE id = '3ba69dbc-2d8e-4259-955e-15d3d9f552a2';
UPDATE public.quotes SET text_jp = '人は「やりたくないこと」をやることでストレスを感じるわけではない。「やるべきだとわかっていること」をやらないことによってストレスを感じる。', text_en = 'Stress primarily comes from not taking action over something you can have some control over.' WHERE id = '43cf15c2-609a-48ac-b6ff-5a4f2337c5f8';
UPDATE public.quotes SET text_jp = '規律とは、嫌いなことをまるで愛してるかのようにやることだ。', text_en = 'Discipline is doing what you hate to do, but doing it like you love it.' WHERE id = '47823530-7eb8-499e-84a1-fd9c3f8a524a';
UPDATE public.quotes SET text_jp = '自分で人生の計画を立てなければ、他人の人生の計画に組み込まれることになるだろう。そしてその計画はお前のために用意されていると思うか？そんなことはない。', text_en = 'If you don''t design your own life plan, chances are you''ll fall into someone else''s plan. And guess what they have planned for you? Not much.' WHERE id = '47f2911a-a4a8-4d1e-94d5-00c553f62f52';
UPDATE public.quotes SET text_jp = '苦しい選択をし続ければ人生は楽になる。楽な選択をし続ければ人生は苦しくなる。', text_en = 'Hard choices, easy life. Easy choices, hard life.' WHERE id = '4b541940-eb5d-4181-ab3f-096c78c443a5';
UPDATE public.quotes SET text_jp = '夢が叶って欲しいと願う者がいて、叶うことを夢見る者もいる。そして夢を叶わせようとする者がいる。', text_en = 'Some people want it to happen, some wish it would happen, others make it happen.' WHERE id = '4d22842c-5b9e-4741-b283-402a805eef86';
UPDATE public.quotes SET text_jp = '規律とは、「今」最も欲しいものと、「人生」で最も欲しいものを天秤にかけることである。', text_en = 'Discipline is choosing between what you want now and what you want most.' WHERE id = '550e8400-e29b-41d4-a716-446655440016';
UPDATE public.quotes SET text_jp = '一度サボるのはただの失敗。二度サボるのは新しい習慣の始まりだ。', text_en = 'Missing once is an accident. Missing twice is the start of a new habit.' WHERE id = '5ab1d664-dbb5-4995-a1a1-2a428740db96';
UPDATE public.quotes SET text_jp = 'みんなはお前の手にした物には嫉妬する。だが、それをどう手に入れたか、その方法は誰もやりたがらない。', text_en = 'Everyone is jealous of what you''ve got. No one is jealous of how you got it.' WHERE id = '769563b9-abc4-4b2f-a6e8-2650f514b4b3';
UPDATE public.quotes SET text_jp = '人は1日でやったことを過大評価し、1年でやり続けることを過小評価する。', text_en = 'Most people overestimate what they can do in a day and underestimate what they can do in a year.' WHERE id = '79e7d6bc-b81f-4e55-94a8-e40b46d71c35';
UPDATE public.quotes SET text_jp = '今自分のやっていることが目標に近づいていないことなら、それは目標から自分を遠ざけている。どんな行動も現状維持では済まされない。', text_en = 'If what you''re doing isn''t moving you toward your goals, it''s moving you away. Nothing is neutral.' WHERE id = '952b0c25-b38d-4563-99bf-537a8dfd5899';
UPDATE public.quotes SET text_jp = '継続が「成功」を保証するわけじゃない。だが、継続しないことは「成功しないこと」を保証する。', text_en = 'Consistency doesn''t guarantee that you''ll be successful. But not being consistent guarantees that you won''t be successful.' WHERE id = 'c8043186-ce10-4a87-8931-3777da6f938a';
UPDATE public.quotes SET text_jp = '今の友人関係を卒業しつつあるあのもどかしさは孤独じゃない。お前の野心が、平凡なグループに対する所属欲求より大きな声で語り始めただけだ。', text_en = 'That annoying feeling when you realize you''ve outgrown your social circle isn''t loneliness — it''s your ambition finally speaking louder than your need to belong.' WHERE id = 'dc77bebb-38fb-422b-9776-e7898ba2c120';
UPDATE public.quotes SET text_jp = '疲れた時に止まるんじゃない。終わった時に止まれ。', text_en = 'Don''t stop when you''re tired. Stop when you''re done.' WHERE id = 'f0f175c6-1658-42d8-97f8-1dc9b4400ff6';

-- 残存名言を全て匿名著者へ (実名全廃)。celebrities の authors 行は残置 (どこからも参照されず不可視)
UPDATE public.quotes SET author_id = '0c606f06-0722-46f8-a8e0-f2f906411120';

INSERT INTO public.quotes (id, author_id, text_en, text_jp, category)
VALUES ('ed40d62a-f15c-4879-984d-af004f11d606', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Sometimes when you''re in a dark place, you think you''ve been buried. But actually, you''ve been planted.', '厳しい辛い時期に直面しているとき、暗い土の中に埋められているように感じるかもしれない。だが本当は芽吹くために植えられているだけだ。', 'hardship')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.quotes (id, author_id, text_en, text_jp, category)
VALUES ('bdba9a09-77a0-4b09-9702-b533dcad15de', '0c606f06-0722-46f8-a8e0-f2f906411120', 'May God have mercy upon my enemies, because I won''t.', '敵に慈悲をかけるのは神だけでいい。俺は容赦しない。', 'mindset')
ON CONFLICT (id) DO NOTHING;

COMMIT;