-- 000_baseline_quotes_authors.sql
--
-- Creates the two tables that existed before this migrations folder was started.
-- Run this first, before 001. Migrations 002, 003, 004, 017, 060 and 071 expect
-- public.authors and public.quotes to exist already.
--
-- The column definitions match the original schema script (April 2026) plus the
-- `nationality` column that was added to authors before 001. Later columns
-- (authors.is_official, quotes.comment_count, ...) are added by the numbered
-- migrations. Row-level security and policies for both tables are set up by 003
-- and 070, so none are defined here.
--
-- Safe to run more than once.

create table if not exists public.authors (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,
    bio_en      text not null default '',
    bio_jp      text not null default '',
    nationality text not null default '',
    image_url   text,
    created_at  timestamptz not null default now()
);

create table if not exists public.quotes (
    id         uuid primary key default gen_random_uuid(),
    author_id  uuid not null references public.authors(id) on delete cascade,
    text_en    text not null,
    text_jp    text not null,
    category   text,
    like_count int not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists idx_quotes_author_id on public.quotes(author_id);
create index if not exists idx_quotes_category on public.quotes(category);

-- Every quote in the app is attributed to this author (see 060 and
-- AppBlocker/Resources/Quotes.json). 060 inserts quotes that point to it.
insert into public.authors (id, name, bio_en, bio_jp)
values (
    '0c606f06-0722-46f8-a8e0-f2f906411120',
    'Anonymous',
    'Quotes whose original author is unknown or attributed to multiple sources.',
    '原著者不明、または複数ソースに帰される名言を集約。'
)
on conflict (id) do nothing;
