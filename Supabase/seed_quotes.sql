-- seed_quotes.sql
--
-- Loads the 68 quotes that ship inside the app (AppBlocker/Resources/Quotes.json)
-- into public.quotes. Run it once, after all migrations (000 to 083).
-- Safe to run more than once: existing rows are left as they are.

insert into public.quotes (id, author_id, text_en, text_jp, category, like_count)
values
    ('049fd4d6-b443-419b-b0e5-1b0b74b90411', '0c606f06-0722-46f8-a8e0-f2f906411120', 'If you have an impulse to act on a goal, you must physically move within 5 seconds or your brain will kill it.', '目標に向けて動く
衝動が湧いたら、
5秒以内に身体を動かせ。
さもないと脳がそれを殺す。', 'action', 0),
    ('08e8a8a6-f9c0-46fd-931f-02208d00c297', '0c606f06-0722-46f8-a8e0-f2f906411120', 'I knew that if I failed I wouldn''t regret that. But I knew the one thing I might regret is not trying.', '失敗しても後悔しないと
分かっていた。
後悔することがあるとするならば、
それは挑戦しないことだとも
分かっていた。', 'action', 0),
    ('0c01c57d-c859-46b3-9778-15b9e8a31c85', '0c606f06-0722-46f8-a8e0-f2f906411120', 'There are people who push work-life balance, but those who have succeeded don''t care. I''ve never regretted trying harder at anything ever.', 'ワークライフバランスを
主張する奴がいるが、
成功者はそんなこと気にしない。
俺はこれまでの人生で何かに
全力で取り組んだことを
一度も後悔したことがない。', 'work-ethic', 0),
    ('0d071cf7-2704-48d2-9fac-50e3736fb9f2', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The magic you''re looking for is in the work you''re avoiding.', 'お前が探している
夢を叶える魔法は、
お前が避けている
作業の中にある。', 'work-ethic', 0),
    ('0d0c9369-3048-44fe-bc18-daaa6106b8ac', '0c606f06-0722-46f8-a8e0-f2f906411120', 'If you do what you''ve always done, you''ll get what you''ve always gotten.', 'いつもと
同じことをすれば、
いつもと
同じ結果しか得られない。', 'mindset', 0),
    ('19d2a16a-5041-4cf6-8370-66c6f76c364b', '0c606f06-0722-46f8-a8e0-f2f906411120', 'You don''t have to be great to get started, but you have to get started to be great.', '何かを始めるのに最初から
優れている必要はない。
ただ、優れた人になるにはまず
始めなければならない。', 'action', 0),
    ('227c491c-9405-4d8d-950b-95feebfe5af2', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The only impossible journey is the one you never begin.', '唯一の達成不可能な目標は、
始めない目標だ。', 'action', 0),
    ('251aa1a5-f330-4936-b9fb-e57e9c44edf2', '0c606f06-0722-46f8-a8e0-f2f906411120', 'When the going gets tough, the tough get going.', '状況が悪くなった時、
強いやつから動き出す。', 'hardship', 0),
    ('256fc2df-51ac-46f6-84b3-d932cf089011', '0c606f06-0722-46f8-a8e0-f2f906411120', 'People think they need a perfect condition to start, when in reality, starting is the perfect condition.', '人は何かを始めるには
完璧な条件を待つ。
でも実際は、
始めることこそが条件を
完璧にする。', 'action', 0),
    ('268d098f-407a-4c4f-aaf1-e031ee6fec39', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Your dream is on the other side of your discipline.', 'お前の夢は、お前の規律の
向こう側にある。', 'discipline', 0),
    ('34bc9224-c85c-419c-a835-1e053db8d496', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The commitments we keep to ourselves when no one is watching shape who we become when everyone is.', '誰も見ていない時に
自分との約束を守れるかが、
他人が自分を見た時に
何者であるかを決める。', 'discipline', 0),
    ('3685cbb5-3ddd-4111-98f5-cfd7d0a61242', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The best revenge is massive success.', '最高のリベンジは、
圧倒的な成功だ。', 'success', 0),
    ('3a870831-3eb0-47d1-9615-cfb9cb6f22c5', '0c606f06-0722-46f8-a8e0-f2f906411120', 'You cannot control what happens to you, but you can control your attitude toward what happens to you.', '自分に起こることは
コントロールできない。
だが、それに対する自分の態度は
コントロールできる。', 'mindset', 0),
    ('3ba69dbc-2d8e-4259-955e-15d3d9f552a2', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The bad days create the story that I''m one day going to tell myself about what I got through. Without the bad days, the story would be way more lame.', '辛い日々こそが、
いつか、自分が何を
乗り越えてきたかという
「物語」を
作ってくれるんだ。
辛い日々がなければ、
その物語はもっとずっと
ダサいものになってしまう。', 'hardship', 0),
    ('42e4b239-ab56-4820-80ff-23672164214b', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Never be afraid to do something new. Remember, amateurs built the ark; professionals built the Titanic.', '新しいことを恐れるな。
覚えておけ、
方舟を造ったのは素人で、
タイタニックを造ったのはプロだ。', 'mindset', 0),
    ('43cf15c2-609a-48ac-b6ff-5a4f2337c5f8', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Stress primarily comes from not taking action over something you can have some control over.', '人は「やりたくないこと」を
やることで
ストレスを感じるわけではない。
「やるべきだとわかっていること」を
やらないこと
によってストレスを感じる。', 'mindset', 0),
    ('47823530-7eb8-499e-84a1-fd9c3f8a524a', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Discipline is doing what you hate to do, but doing it like you love it.', '規律とは、
嫌いなことをまるで
愛してるかのようにやることだ。', 'discipline', 0),
    ('47f2911a-a4a8-4d1e-94d5-00c553f62f52', '0c606f06-0722-46f8-a8e0-f2f906411120', 'If you don''t design your own life plan, chances are you''ll fall into someone else''s plan. And guess what they have planned for you? Not much.', '自分で人生の計画を
立てなければ、
他人の人生の計画に
組み込まれることになるだろう。
そしてその計画は
お前のために
用意されていると思うか？
そんなことはない。', 'mindset', 0),
    ('4b541940-eb5d-4181-ab3f-096c78c443a5', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Hard choices, easy life. Easy choices, hard life.', '苦しい選択をし続ければ
人生は楽になる。
楽な選択をし続ければ
人生は苦しくなる。', 'discipline', 0),
    ('4d22842c-5b9e-4741-b283-402a805eef86', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Some people want it to happen, some wish it would happen, others make it happen.', '夢が叶って欲しいと
願う者がいて、
叶うことを
夢見る者もいる。
そして夢を叶わせようとする
者がいる。', 'action', 0),
    ('550e8400-e29b-41d4-a716-446655440001', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The job''s not finished.', '仕事はまだ終わっていない。', 'sports', 0),
    ('550e8400-e29b-41d4-a716-446655440002', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Hard work beats talent when talent doesn''t work hard.', '才能が努力を怠れば、
努力が才能を超える。', 'motivation', 0),
    ('550e8400-e29b-41d4-a716-446655440004', '0c606f06-0722-46f8-a8e0-f2f906411120', 'It does not matter how slowly you go as long as you do not stop.', '止まりさえしなければ、
どんなに
ゆっくりでも構わない。', 'philosophy', 0),
    ('550e8400-e29b-41d4-a716-446655440005', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Yesterday you said tomorrow.', '昨日、お前は明日やると
言った。', 'motivation', 0),
    ('550e8400-e29b-41d4-a716-446655440010', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Your time is limited, don''t waste it living someone else''s life.', 'あなたの時間は
限られている。
他人の人生を生きて
無駄にするな。', 'life', 0),
    ('550e8400-e29b-41d4-a716-446655440016', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Discipline is choosing between what you want now and what you want most.', '規律とは、「今」最も
欲しいものと、
「人生」で最も欲しいものを
天秤にかけることである。', 'philosophy', 0),
    ('550e8400-e29b-41d4-a716-446655440017', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The pain of discipline is far less than the pain of regret.', '規律の痛みは、
後悔の痛みよりはるかに軽い。', 'motivation', 0),
    ('550e8400-e29b-41d4-a716-446655440018', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Focus on being productive instead of busy.', '忙しくするのではなく、
生産的であることに集中しろ。', 'success', 0),
    ('5544df6f-a850-49e7-964b-5ab4e16814b3', '0c606f06-0722-46f8-a8e0-f2f906411120', 'You will never feel like it. Motivation is garbage.', 'やる気なんて
永遠に湧いてこない。
モチベーションはゴミだ。', 'discipline', 0),
    ('571475a2-7452-4d0d-a387-8f41bc32e134', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Move out of your comfort zone. You can only grow if you are willing to feel awkward and uncomfortable when you try something new.', '快適な場所から出ろ。
新しいことに挑戦して
気まずさや不快さを
感じる覚悟があってこそ、
人は成長する。', 'growth', 0),
    ('57a93d30-1e50-4943-b8f1-b2de048d9a25', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Successful people see opportunity in every failure. Normal people see failure in every opportunity. Both are right. Only one gets rich.', '成功者はあらゆる失敗に
チャンスを見出す。
凡人はあらゆるチャンスに
失敗を見出す。
どちらも正しい。
だが、金持ちになるのは
片方だけだ。', 'mindset', 0),
    ('58b0ee33-d271-4da4-9f83-9ca002377318', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Don''t wish it were easier. Wish you were better.', '「もっと楽ならいいのに」なんて
思うな。
「もっと強くなりたい」と思え。', 'growth', 0),
    ('5ab1d664-dbb5-4995-a1a1-2a428740db96', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Missing once is an accident. Missing twice is the start of a new habit.', '一度サボるのは
ただの失敗。
二度サボるのは
新しい習慣の始まりだ。', 'consistency', 0),
    ('5baeb2de-74da-4e47-88d5-36bbf6acc03a', '0c606f06-0722-46f8-a8e0-f2f906411120', 'I''d rather go too far than not far enough.', '足りないより、
行き過ぎる方がマシだ。', 'work-ethic', 0),
    ('604fa0c7-6ddd-4839-a97e-f2120f2d15f5', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Your dreams don''t care how you feel. Get up and go to work.', 'お前の夢はお前の気分なんて
気にしない。
起きて仕事を始めろ。', 'work-ethic', 0),
    ('630cd84c-2bfe-4488-9e52-e0c66929093c', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Life without challenges is just existence. Don''t just exist — go live.', '挑戦のない人生は
ただの存在だ。
ただ存在するな、生きろ。', 'mindset', 0),
    ('66b8e16c-d763-469d-bad1-898df9cf162b', '0c606f06-0722-46f8-a8e0-f2f906411120', '5, 4, 3, 2, 1 — go. Don''t let your brain talk you out of it.', '5、4、3、2、1
— やれ。
脳に止められる前に動け。', 'action', 0),
    ('6f21188d-369c-4c53-b9df-09adc8c8c30c', '0c606f06-0722-46f8-a8e0-f2f906411120', 'You''re one decision away from a completely different life.', 'お前はたった一つの決断で、
全く違う人生を
手に入れられる。', 'action', 0),
    ('7578a51b-abb0-48af-ac4e-53295a4ff100', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Don''t make a permanent decision based on a temporary emotion.', '一時の感情で
永遠の決断をするな。', 'mindset', 0),
    ('769563b9-abc4-4b2f-a6e8-2650f514b4b3', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Everyone is jealous of what you''ve got. No one is jealous of how you got it.', 'みんなはお前の手にした
物には嫉妬する。
だが、
それをどう手に入れたか、
その方法は
誰もやりたがらない。', 'success', 0),
    ('79e7d6bc-b81f-4e55-94a8-e40b46d71c35', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Most people overestimate what they can do in a day and underestimate what they can do in a year.', '人は1日でやったことを
過大評価し、
1年でやり続けることを
過小評価する。', 'consistency', 0),
    ('81d49d6e-d36c-43ee-979c-6649a36c6629', '0c606f06-0722-46f8-a8e0-f2f906411120', 'If you don''t fail, you''re not even trying.', '失敗していないなら、
挑戦すらしていない。', 'failure', 0),
    ('8e278d91-dd8a-40d1-bd10-d96fbbc20e1f', '0c606f06-0722-46f8-a8e0-f2f906411120', 'If you decide that you''re going to do only the things you know are going to work, you''re going to leave a lot of opportunity on the table.', 'うまくいくと
分かっていることだけをやると
決めた瞬間、
お前は数多くの
チャンスを取りこぼす。', 'action', 0),
    ('8fcf0653-c1f7-4943-a084-7c4dd493dbe4', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The best time to plant a tree was twenty years ago. The second best time is now.', '木を植えるのに最も良い時は
20年前だった。
次に良いのは今だ。', 'action', 0),
    ('9414cd4e-4396-48e5-990f-0c433d1888ad', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Your future self is watching you right now through your memories.', '未来のお前が、
思い出を通して
今のお前を見ている。', 'mindset', 0),
    ('952b0c25-b38d-4563-99bf-537a8dfd5899', '0c606f06-0722-46f8-a8e0-f2f906411120', 'If what you''re doing isn''t moving you toward your goals, it''s moving you away. Nothing is neutral.', '今自分のやっていることが
目標に近づいていないことなら、
それは目標から自分を遠ざけている。
どんな行動も
現状維持では済まされない。', 'focus', 0),
    ('9f97aee9-4c60-4ca8-9676-0192fa3dcc75', '0c606f06-0722-46f8-a8e0-f2f906411120', 'You are in danger of living a life so comfortable and soft that you will die without ever realizing your true potential.', 'あまりに快適で生ぬるい
人生を送って本当の自分の
ポテンシャルを知らないまま
人生を終えることになるぞ。', 'mindset', 0),
    ('aaa12abd-2b7d-47db-ba8e-91f7da62c51c', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Don''t expect to be motivated every day to get out there and make things happen. You won''t be. Don''t count on motivation. Count on discipline.', '毎日モチベーションが出ると思うな。
出ないと思え。
モチベーションに頼るな。
規律に頼れ。', 'discipline', 0),
    ('ab7a8e88-925a-4f24-bda2-277b53ed1c6e', '0c606f06-0722-46f8-a8e0-f2f906411120', 'When you want to succeed as bad as you want to breathe, then you''ll be successful.', '呼吸したいのと同じくらい
成功したくなったとき、
お前は成功する。', 'work-ethic', 0),
    ('c26676c6-711f-4f0b-9729-9239a35af1a5', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The more you sweat in training, the less you bleed in combat.', '訓練で汗を流すほど、
戦場で血を流す量は減る。', 'work-ethic', 0),
    ('c8043186-ce10-4a87-8931-3777da6f938a', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Consistency doesn''t guarantee that you''ll be successful. But not being consistent guarantees that you won''t be successful.', '継続が「成功」を
保証するわけじゃない。
だが、継続しないことは
「成功しないこと」を
保証する。', 'consistency', 0),
    ('ca148cc6-1002-4071-8a67-02dd59af9808', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Winners focus on winning. Losers focus on winners.', '勝者は勝利に集中する。
敗者は勝者に集中する。', 'focus', 0),
    ('cf0ee24e-06c7-4701-b20c-58d60783478b', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Success is nothing more than a few simple disciplines, practiced every day.', '成功とは、
いくつかの単純な規律を
毎日実践すること、
それだけだ。', 'consistency', 0),
    ('d43d499a-da9d-4c5b-b258-8683a4039dd9', '0c606f06-0722-46f8-a8e0-f2f906411120', 'When something is important enough, you do it even if the odds are not in your favor.', '本当にやりたいなら、
勝率が低くてもやる。', 'action', 0),
    ('d676110a-1326-417c-bfac-7ddf0610df9d', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Discipline starts with the small choices you make every single day.', '規律は毎日の
小さな選択から始まる。', 'discipline', 0),
    ('dbcb4b45-4117-4f3e-aa06-6b6811f95042', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Imagine you''re the hero of a movie. And the movie begins now. What would the hero do right now?', '自分が映画の主人公だと
想像してみろ。
そしてその映画は
今始まった。
主人公なら今、何をする？', 'mindset', 0),
    ('dc77bebb-38fb-422b-9776-e7898ba2c120', '0c606f06-0722-46f8-a8e0-f2f906411120', 'That annoying feeling when you realize you''ve outgrown your social circle isn''t loneliness — it''s your ambition finally speaking louder than your need to belong.', '今の友人関係を
卒業しつつあるあの
もどかしさは孤独じゃない。
お前の野心が、
平凡なグループに対する
所属欲求より
大きな声で語り始めただけだ。', 'growth', 0),
    ('deb480d9-b80f-40a8-b858-4ac3d68973c4', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Shoot for the moon. Even if you miss, you''ll land among the stars.', '月を狙え。
外しても、
星々の中に
着陸できる。', 'self-belief', 0),
    ('df5d5b4e-0791-442e-b2fe-b57f009d484c', '0c606f06-0722-46f8-a8e0-f2f906411120', 'You don''t get what you want. You get what you''re committed to.', '望んだものは手に入らない。
専念したものが手に入る。', 'discipline', 0),
    ('e64662dd-44ca-4357-8ac1-f2f3b31520ad', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Either you run the day, or the day runs you.', '一日を支配するか、一日に
支配されるか、どちらか選べ。', 'discipline', 0),
    ('ea141cf2-cd86-43ab-8b7f-276537731721', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Best case you win. Worst case it won''t matter.', '最良の場合は勝つ。
最悪の場合？
そんなことはどうでもいい。', 'action', 0),
    ('f0f175c6-1658-42d8-97f8-1dc9b4400ff6', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Don''t stop when you''re tired. Stop when you''re done.', '疲れた時に
止まるんじゃない。
終わった時に止まれ。', 'discipline', 0),
    ('f191432e-acde-4573-a8ae-ab011931a81c', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Discipline is the most important thing in the world. Without it, you have nothing.', '規律は世界で
最も重要なものだ。
それなしには何もない。', 'discipline', 0),
    ('f465c48d-e044-4204-852c-7826d914a628', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Compare yourself to who you were yesterday, not to who someone else is today.', '他人と比べるな。
昨日の自分と比べろ。', 'growth', 0),
    ('fb306959-28b7-4f16-a67a-8e771a08b3cd', '0c606f06-0722-46f8-a8e0-f2f906411120', 'The best time to start was yesterday. The next best time is now.', '始めるのに
一番良かったのは昨日。
次にいいのは今だ。', 'action', 0),
    ('fbf039a7-80ce-425d-b6b7-19dc406bf6a3', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Stop waiting for the right moment. There is no such thing.', '正しいタイミングを待つな。
そんなものは存在しない。', 'action', 0),
    ('ed40d62a-f15c-4879-984d-af004f11d606', '0c606f06-0722-46f8-a8e0-f2f906411120', 'Sometimes when you''re in a dark place, you think you''ve been buried. But actually, you''ve been planted.', '厳しい辛い時期に
直面しているとき、
暗い土の中に
埋められているように
感じるかもしれない。
だが本当は芽吹くために
植えられているだけだ。', 'hardship', 0),
    ('bdba9a09-77a0-4b09-9702-b533dcad15de', '0c606f06-0722-46f8-a8e0-f2f906411120', 'May God have mercy upon my enemies, because I won''t.', '敵に慈悲をかけるのは
神だけでいい。
俺は容赦しない。', 'mindset', 0)
on conflict (id) do nothing;
