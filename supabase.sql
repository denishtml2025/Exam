-- PastPapers: run this once in Supabase → SQL Editor → New query → Run

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null default 'student' check (role in ('student','admin'))
);
create table papers (
  id uuid primary key default gen_random_uuid(),
  title text not null, subject text not null, level text not null, year text not null,
  file_path text not null, file_name text not null,
  created_at timestamptz not null default now()
);
create table payments (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid references papers(id) on delete set null,
  paper_title text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  code text not null unique,
  amount integer not null,
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  created_at timestamptz not null default now()
);
create table settings (
  id int primary key default 1 check (id = 1),
  phone text not null, name text not null, price integer not null default 50
);
insert into settings (phone, name, price) values ('0700000000', 'PastPapers', 50);

-- helper: is the current user an admin?
create function is_admin() returns boolean language sql security definer set search_path = public stable as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'admin') $$;

-- create a student profile automatically on sign-up
create function handle_new_user() returns trigger language plpgsql security definer set search_path = public as
$$ begin
  insert into profiles (id, name) values (new.id, coalesce(new.raw_user_meta_data->>'name', 'Student'));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- row level security
alter table profiles enable row level security;
alter table papers   enable row level security;
alter table payments enable row level security;
alter table settings enable row level security;

create policy "own profile"    on profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy "read papers"    on papers   for select to authenticated using (true);
create policy "admin add"      on papers   for insert to authenticated with check (is_admin());
create policy "admin delete"   on papers   for delete to authenticated using (is_admin());
create policy "read payments"  on payments for select to authenticated using (user_id = auth.uid() or is_admin());
create policy "submit payment" on payments for insert to authenticated with check (user_id = auth.uid() and status = 'pending');
create policy "admin review"   on payments for update to authenticated using (is_admin()) with check (is_admin());
create policy "read settings"  on settings for select to authenticated using (true);
create policy "admin settings" on settings for update to authenticated using (is_admin()) with check (is_admin());

-- private file storage (20 MB per file)
insert into storage.buckets (id, name, public, file_size_limit) values ('papers', 'papers', false, 20971520);

create policy "admin upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'papers' and is_admin());
create policy "admin remove" on storage.objects for delete to authenticated
  using (bucket_id = 'papers' and is_admin());
create policy "download if unlocked" on storage.objects for select to authenticated
  using (bucket_id = 'papers' and (
    is_admin()
    or (select price from settings where id = 1) = 0
    or exists (select 1 from payments py join papers pa on pa.id = py.paper_id
               where pa.file_path = storage.objects.name and py.user_id = auth.uid() and py.status = 'confirmed')
  ));

-- AFTER you sign up in the app with your own email, make yourself admin:
-- update profiles set role = 'admin' where id = (select id from auth.users where email = 'YOUR-EMAIL@example.com');
