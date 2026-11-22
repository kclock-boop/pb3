-- 신규 전용 Supabase 프로젝트에서 한 번 실행합니다. 기존 업무 테이블은 변경하지 않습니다.
begin;
create schema if not exists approval_private;
revoke all on schema approval_private from public,anon,authenticated;
create table public.company_settings(id integer primary key check(id=1),data jsonb not null default '{}');
insert into public.company_settings values(1,'{}');
create table public.documents(
 id uuid primary key default gen_random_uuid(),owner_id uuid not null references auth.users(id),
 data jsonb not null check(jsonb_typeof(data)='object' and octet_length(data::text)<200000),
 status text not null default '임시저장' check(status in ('임시저장','검토완료')),
 source text not null default '',version integer not null default 1,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create index documents_owner_idx on public.documents(owner_id);
create table public.document_history(id bigint generated always as identity primary key,
 document_id uuid not null references public.documents(id),actor_id uuid not null,
 data jsonb not null,status text not null,version integer not null,created_at timestamptz not null default now());
create index history_document_idx on public.document_history(document_id);
alter table public.company_settings enable row level security;
alter table public.documents enable row level security;
alter table public.document_history enable row level security;
-- app_metadata は管理者のみ設定可能。user_metadata は権限判定に使用しません。
create policy settings_read on public.company_settings for select to authenticated
 using ((select auth.jwt()->'app_metadata'->>'org_id')='company-main');
create policy settings_update on public.company_settings for update to authenticated
 using ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and (select auth.jwt()->'app_metadata'->>'role')='admin')
 with check ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and (select auth.jwt()->'app_metadata'->>'role')='admin');
create policy docs_read on public.documents for select to authenticated
 using ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and (owner_id=(select auth.uid()) or (select auth.jwt()->'app_metadata'->>'role')='admin'));
create policy docs_insert on public.documents for insert to authenticated
 with check ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and owner_id=(select auth.uid()));
create policy docs_update on public.documents for update to authenticated
 using ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and (owner_id=(select auth.uid()) or (select auth.jwt()->'app_metadata'->>'role')='admin'))
 with check ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and (owner_id=(select auth.uid()) or (select auth.jwt()->'app_metadata'->>'role')='admin'));
create policy history_read on public.document_history for select to authenticated
 using (exists(select 1 from public.documents d where d.id=document_id));
revoke all on public.documents,public.company_settings,public.document_history from anon,authenticated;
grant select,insert on public.documents to authenticated;
grant update(data,status,source) on public.documents to authenticated;
grant select on public.company_settings,public.document_history to authenticated;
grant update(data) on public.company_settings to authenticated;
-- 履歴はクライアントから書き換え不可。トリガー専用の非公開関数が記録します。
create function approval_private.before_save() returns trigger language plpgsql set search_path='' as $$
begin
 if TG_OP='UPDATE' then
  if new.owner_id<>old.owner_id or new.id<>old.id then raise exception 'immutable identity'; end if;
  new.version:=old.version+1;new.created_at:=old.created_at;
 else new.version:=1;new.created_at:=now();end if;
 new.updated_at:=now();return new;
end $$;
create function approval_private.record_history() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'authenticated user required';end if;
 insert into public.document_history(document_id,actor_id,data,status,version)
 values(new.id,auth.uid(),new.data,new.status,new.version);
 return new;
end $$;
revoke all on function approval_private.before_save(),approval_private.record_history() from public,anon,authenticated;
create trigger documents_before before insert or update on public.documents for each row execute function approval_private.before_save();
create trigger documents_history after insert or update on public.documents for each row execute function approval_private.record_history();
create table public.user_profiles(user_id uuid primary key references auth.users(id),data jsonb not null default '{}');
alter table public.user_profiles enable row level security;
revoke all on public.user_profiles from anon,authenticated;
grant select,insert on public.user_profiles to authenticated;
grant update(data) on public.user_profiles to authenticated;
create policy profile_read on public.user_profiles for select to authenticated
 using ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and user_id=(select auth.uid()));
create policy profile_insert on public.user_profiles for insert to authenticated
 with check ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and user_id=(select auth.uid()));
create policy profile_update on public.user_profiles for update to authenticated
 using ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and user_id=(select auth.uid()))
 with check ((select auth.jwt()->'app_metadata'->>'org_id')='company-main' and user_id=(select auth.uid()));
commit;
