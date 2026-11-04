
-- ============================================================
-- KOVOIT V2 — SCHEMA COMPLET CORRIGE
-- PostgreSQL / Supabase
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 1. TABLES
-- ============================================================

create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    full_name text not null default '',
    email text not null,
    department text,
    phone text,
    avatar_url text,
    role text not null default 'employee'
        check (role in ('employee','admin')),
    active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.trips (
    id bigint generated always as identity primary key,
    driver_id uuid not null references public.profiles(id) on delete cascade,
    from_location text not null,
    to_location text not null,
    trip_date date not null,
    trip_time time not null,
    seats_total integer not null check (seats_total between 1 and 8),
    recurrence text,
    comment text,
    status text not null default 'active'
        check (status in ('active','cancelled','completed')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.bookings (
    id bigint generated always as identity primary key,
    trip_id bigint not null references public.trips(id) on delete cascade,
    passenger_id uuid not null references public.profiles(id) on delete cascade,
    status text not null default 'confirmed'
        check (status in ('confirmed','cancelled')),
    created_at timestamptz not null default now(),
    unique (trip_id, passenger_id)
);

create table if not exists public.messages (
    id bigint generated always as identity primary key,
    trip_id bigint references public.trips(id) on delete cascade,
    sender_id uuid not null references public.profiles(id) on delete cascade,
    receiver_id uuid not null references public.profiles(id) on delete cascade,
    body text not null check (length(trim(body)) > 0),
    created_at timestamptz not null default now()
);

create table if not exists public.notifications (
    id bigint generated always as identity primary key,
    user_id uuid not null references public.profiles(id) on delete cascade,
    type text not null,
    title text,
    body text,
    payload jsonb,
    read_at timestamptz,
    created_at timestamptz not null default now()
);

create table if not exists public.reports (
    id bigint generated always as identity primary key,
    reporter_id uuid not null references public.profiles(id) on delete cascade,
    reported_user_id uuid references public.profiles(id) on delete set null,
    trip_id bigint references public.trips(id) on delete set null,
    reason text not null,
    description text,
    status text not null default 'open'
        check (status in ('open','reviewing','closed')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- ============================================================
-- 2. INDEX
-- ============================================================

create index if not exists idx_trips_date
on public.trips(trip_date);

create index if not exists idx_trips_route
on public.trips(from_location,to_location);

create index if not exists idx_trips_driver
on public.trips(driver_id);

create index if not exists idx_bookings_trip
on public.bookings(trip_id);

create index if not exists idx_bookings_passenger
on public.bookings(passenger_id);

create index if not exists idx_messages_receiver
on public.messages(receiver_id);

-- ============================================================
-- 3. CREATION AUTOMATIQUE DES PROFILS
-- ============================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (
        id,
        full_name,
        email
    )
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name',''),
        coalesce(new.email,'')
    )
    on conflict (id) do nothing;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute procedure public.handle_new_user();

-- Création des profils manquants pour les anciens comptes.

insert into public.profiles (id,full_name,email)
select
    id,
    coalesce(raw_user_meta_data->>'full_name',''),
    coalesce(email,'')
from auth.users
on conflict (id) do nothing;

-- ============================================================
-- 4. VERIFICATION ADMINISTRATEUR
-- ============================================================

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.profiles
        where id = (select auth.uid())
          and role = 'admin'
          and active = true
    );
$$;

-- ============================================================
-- 5. PROTECTION DES PROFILS
-- ============================================================

create or replace function public.protect_profile_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if (select auth.uid()) is not null
       and not (select public.is_admin()) then

        if new.id is distinct from old.id
           or new.email is distinct from old.email
           or new.role is distinct from old.role
           or new.active is distinct from old.active
           or new.created_at is distinct from old.created_at then

            raise exception 'Modification de profil non autorisée';
        end if;
    end if;

    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists protect_profile_fields_trigger
on public.profiles;

create trigger protect_profile_fields_trigger
before update on public.profiles
for each row
execute function public.protect_profile_fields();

-- ============================================================
-- 6. RESERVATION D'UN TRAJET
-- ============================================================

create or replace function public.book_trip(p_trip_id bigint)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_trip public.trips;
    v_booking public.bookings;
    v_user uuid := (select auth.uid());
    v_count integer;
begin
    if v_user is null then
        raise exception 'Utilisateur non connecté';
    end if;

    if not exists (
        select 1
        from public.profiles
        where id = v_user and active = true
    ) then
        raise exception 'Compte désactivé ou introuvable';
    end if;

    select *
    into v_trip
    from public.trips
    where id = p_trip_id
    for update;

    if not found then
        raise exception 'Trajet introuvable';
    end if;

    if v_trip.status <> 'active' then
        raise exception 'Trajet indisponible';
    end if;

    if v_trip.driver_id = v_user then
        raise exception 'Le conducteur ne peut pas réserver son propre trajet';
    end if;

    select count(*)
    into v_count
    from public.bookings
    where trip_id = p_trip_id
      and status = 'confirmed';

    if v_count >= v_trip.seats_total then
        raise exception 'Il n’y a plus de place disponible';
    end if;

    select *
    into v_booking
    from public.bookings
    where trip_id = p_trip_id
      and passenger_id = v_user
    for update;

    if found then
        if v_booking.status = 'confirmed' then
            raise exception 'Vous avez déjà réservé ce trajet';
        end if;

        update public.bookings
        set status = 'confirmed',
            created_at = now()
        where id = v_booking.id
        returning * into v_booking;
    else
        insert into public.bookings (
            trip_id,
            passenger_id,
            status
        )
        values (
            p_trip_id,
            v_user,
            'confirmed'
        )
        returning * into v_booking;
    end if;

    return v_booking;
end;
$$;

revoke all on function public.book_trip(bigint) from public;
grant execute on function public.book_trip(bigint) to authenticated;

-- ============================================================
-- 7. NOMBRE DE PLACES RESERVEES PAR TRAJET
-- ============================================================

create or replace function public.get_trip_booking_counts(
    p_trip_ids bigint[]
)
returns table (
    trip_id bigint,
    confirmed_count bigint
)
language sql
stable
security definer
set search_path = ''
as $$
    select
        t.id,
        count(b.id)::bigint
    from public.trips t
    left join public.bookings b
        on b.trip_id = t.id
       and b.status = 'confirmed'
    where
        (select auth.uid()) is not null
        and t.id = any(coalesce(p_trip_ids, '{}'::bigint[]))
        and t.status = 'active'
    group by t.id;
$$;

revoke all on function public.get_trip_booking_counts(bigint[]) from public;
revoke all on function public.get_trip_booking_counts(bigint[]) from anon;

grant execute on function public.get_trip_booking_counts(bigint[])
to authenticated;

-- ============================================================
-- 8. ACTIVATION RLS
-- ============================================================

alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.bookings enable row level security;
alter table public.messages enable row level security;
alter table public.notifications enable row level security;
alter table public.reports enable row level security;

-- ============================================================
-- 9. POLITIQUES PROFILS
-- ============================================================

drop policy if exists profiles_select on public.profiles;

create policy profiles_select
on public.profiles
for select
to authenticated
using (
    active = true
    or id = (select auth.uid())
    or (select public.is_admin())
);

drop policy if exists profiles_update_self on public.profiles;

create policy profiles_update_self
on public.profiles
for update
to authenticated
using (
    id = (select auth.uid())
    or (select public.is_admin())
)
with check (
    id = (select auth.uid())
    or (select public.is_admin())
);

-- ============================================================
-- 10. POLITIQUES TRAJETS
-- ============================================================

drop policy if exists trips_select on public.trips;

create policy trips_select
on public.trips
for select
to authenticated
using (
    status = 'active'
    or driver_id = (select auth.uid())
    or (select public.is_admin())
);

drop policy if exists trips_insert on public.trips;

create policy trips_insert
on public.trips
for insert
to authenticated
with check (
    driver_id = (select auth.uid())
);

drop policy if exists trips_update on public.trips;

create policy trips_update
on public.trips
for update
to authenticated
using (
    driver_id = (select auth.uid())
    or (select public.is_admin())
)
with check (
    driver_id = (select auth.uid())
    or (select public.is_admin())
);

drop policy if exists trips_delete on public.trips;

create policy trips_delete
on public.trips
for delete
to authenticated
using (
    driver_id = (select auth.uid())
    or (select public.is_admin())
);

-- ============================================================
-- 11. POLITIQUES RESERVATIONS
-- ============================================================

drop policy if exists bookings_select on public.bookings;

create policy bookings_select
on public.bookings
for select
to authenticated
using (
    passenger_id = (select auth.uid())
    or exists (
        select 1
        from public.trips t
        where t.id = trip_id
          and t.driver_id = (select auth.uid())
    )
    or (select public.is_admin())
);

drop policy if exists bookings_delete on public.bookings;

create policy bookings_delete
on public.bookings
for delete
to authenticated
using (
    passenger_id = (select auth.uid())
    or exists (
        select 1
        from public.trips t
        where t.id = trip_id
          and t.driver_id = (select auth.uid())
    )
    or (select public.is_admin())
);

-- ============================================================
-- 12. POLITIQUES MESSAGES
-- ============================================================

drop policy if exists messages_select on public.messages;

create policy messages_select
on public.messages
for select
to authenticated
using (
    sender_id = (select auth.uid())
    or receiver_id = (select auth.uid())
    or (select public.is_admin())
);

drop policy if exists messages_insert on public.messages;

create policy messages_insert
on public.messages
for insert
to authenticated
with check (
    sender_id = (select auth.uid())
    and exists (
        select 1
        from public.profiles
        where id = receiver_id
          and active = true
    )
);

-- ============================================================
-- 13. POLITIQUES NOTIFICATIONS
-- ============================================================

drop policy if exists notifications_select on public.notifications;

create policy notifications_select
on public.notifications
for select
to authenticated
using (
    user_id = (select auth.uid())
);

drop policy if exists notifications_update on public.notifications;

create policy notifications_update
on public.notifications
for update
to authenticated
using (
    user_id = (select auth.uid())
)
with check (
    user_id = (select auth.uid())
);

-- ============================================================
-- 14. POLITIQUES SIGNALEMENTS
-- ============================================================

drop policy if exists reports_insert on public.reports;

create policy reports_insert
on public.reports
for insert
to authenticated
with check (
    reporter_id = (select auth.uid())
);

drop policy if exists reports_select on public.reports;

create policy reports_select
on public.reports
for select
to authenticated
using (
    reporter_id = (select auth.uid())
    or (select public.is_admin())
);

drop policy if exists reports_update on public.reports;

create policy reports_update
on public.reports
for update
to authenticated
using (
    (select public.is_admin())
)
with check (
    (select public.is_admin())
);

-- ============================================================
-- 15. AUTORISATIONS
-- ============================================================

revoke all on public.profiles,
              public.trips,
              public.bookings,
              public.messages,
              public.notifications,
              public.reports
from anon;

grant select on public.profiles to authenticated;

-- Le profil peut uniquement modifier ses champs non sensibles.
revoke update on public.profiles from authenticated;

grant update (
    full_name,
    department,
    phone,
    avatar_url,
    updated_at
)
on public.profiles to authenticated;

-- Trajets
grant select, insert, update, delete
on public.trips to authenticated;

-- Réservations
grant select, delete
on public.bookings to authenticated;

-- Messages
grant select, insert
on public.messages to authenticated;

-- Notifications
grant select, update
on public.notifications to authenticated;

-- Signalements
grant select, insert, update
on public.reports to authenticated;

-- Séquences des identifiants
grant usage, select
on all sequences in schema public
to authenticated;

-- ============================================================
-- FIN DU SCHEMA KOVOIT
-- ============================================================
