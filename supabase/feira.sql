-- =====================================================================
-- Feira Origins · banco de dados (no mesmo Supabase do Habbo Music)
-- Usa o mesmo login com Discord e os mesmos perfis, admins e bans.
-- Tudo da feira fica em tabelas "feira_..." e no bucket "feira".
-- Cole no SQL Editor do Supabase e clique em "Run". Pode rodar de novo sem problema.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Nick no Origins: guardado no perfil. O Origins bloqueia consultas
-- automáticas, então o nick é conferido pelo print, na moderação.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists origins_nick  text;
alter table public.profiles add column if not exists origins_hotel text;
alter table public.profiles add column if not exists feira_limit   integer not null default 10;
alter table public.profiles drop constraint if exists profiles_feira_limit_check;
alter table public.profiles add constraint profiles_feira_limit_check check (feira_limit between 0 and 1000);

create or replace function public.feira_meu_nick(p_nick text, p_hotel text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre com o Discord primeiro.'; end if;
  if p_hotel not in ('com.br','com','es') then raise exception 'Hotel inválido.'; end if;
  if p_nick !~ '^[A-Za-z0-9=?!@:.,_-]{1,32}$' then raise exception 'Nick inválido: use só letras, números e = ? ! @ : . , _ -'; end if;
  update public.profiles set origins_nick = p_nick, origins_hotel = p_hotel where id = auth.uid();
end $$;

-- ---------------------------------------------------------------------
-- Anúncios da feira. Preço só em moedas do jogo.
-- ---------------------------------------------------------------------
create table if not exists public.feira_anuncios (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  tipo        text not null default 'raro' check (tipo in ('raro','mobi')),
  nome        text not null check (char_length(nome) between 1 and 60),
  preco       integer not null check (preco between 1 and 100000000),
  qtd         integer not null default 1 check (qtd between 1 and 999),
  nota        text check (char_length(nota) <= 140),
  print_path  text not null,
  status      text not null default 'ativo' check (status in ('ativo','vendido','removido')),
  ok          boolean not null default false,
  rejected    text,
  created_at  timestamptz not null default now()
);
create index if not exists feira_anuncios_status_idx on public.feira_anuncios (status, created_at desc);
create index if not exists feira_anuncios_user_idx on public.feira_anuncios (user_id);

create or replace function public.feira_antes_de_inserir()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.profiles; ativos int;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null or p.discord_id is null then raise exception 'Entre com o Discord para anunciar.'; end if;
  if p.banned then raise exception 'Sua conta não pode anunciar.'; end if;
  if p.origins_nick is null then raise exception 'Coloque seu nick do Origins antes de anunciar.'; end if;
  select count(*) into ativos from public.feira_anuncios where user_id = p.id and status = 'ativo';
  if ativos >= p.feira_limit then
    raise exception 'Você já tem % anúncios ativos, que é o seu limite. Marque algum como vendido ou apague para anunciar outro. Quer mais espaço? Fale com a moderação.', ativos;
  end if;
  if (select count(*) from public.feira_anuncios where user_id = p.id and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'Muitos anúncios em pouco tempo. Tente de novo amanhã.';
  end if;
  if (coalesce(new.nota, '') || ' ' || new.nome) ~* '(r\$|reais|pix)' then raise exception 'Anúncios são só em moedas do jogo.'; end if;
  if split_part(new.print_path, '/', 1) <> p.id::text then raise exception 'Print inválido.'; end if;
  new.user_id := p.id; new.status := 'ativo'; new.ok := false; new.rejected := null; new.created_at := now();
  return new;
end $$;
drop trigger if exists feira_insert on public.feira_anuncios;
create trigger feira_insert before insert on public.feira_anuncios
  for each row execute function public.feira_antes_de_inserir();

-- removido pela moderação não volta; reativar respeita o limite; nova observação sem reais
create or replace function public.feira_antes_de_editar()
returns trigger language plpgsql security definer set search_path = public as $$
declare lim int; ativos int;
begin
  if old.status = 'removido' and not public.is_admin() then raise exception 'Este anúncio foi removido.'; end if;
  if coalesce(new.nota, '') ~* '(r\$|reais|pix)' then raise exception 'Anúncios são só em moedas do jogo.'; end if;
  if new.status = 'ativo' and old.status <> 'ativo' and not public.is_admin() then
    select feira_limit into lim from public.profiles where id = old.user_id;
    select count(*) into ativos from public.feira_anuncios where user_id = old.user_id and status = 'ativo';
    if ativos >= lim then raise exception 'Você já está no limite de % anúncios ativos. Marque outro como vendido ou apague antes de reativar.', lim; end if;
  end if;
  return new;
end $$;
drop trigger if exists feira_update on public.feira_anuncios;
create trigger feira_update before update on public.feira_anuncios
  for each row execute function public.feira_antes_de_editar();

-- ---------------------------------------------------------------------
-- Denúncias (só a moderação vê)
-- ---------------------------------------------------------------------
create table if not exists public.feira_denuncias (
  id          bigint generated always as identity primary key,
  anuncio_id  bigint not null references public.feira_anuncios(id) on delete cascade,
  reporter    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  motivo      text not null check (char_length(motivo) between 1 and 300),
  created_at  timestamptz not null default now()
);
create or replace function public.feira_denuncia_antes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entre com o Discord para denunciar.'; end if;
  if (select count(*) from public.feira_denuncias where reporter = auth.uid() and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'Limite de denúncias por dia atingido.';
  end if;
  new.reporter := auth.uid(); new.created_at := now();
  return new;
end $$;
drop trigger if exists feira_denuncia_insert on public.feira_denuncias;
create trigger feira_denuncia_insert before insert on public.feira_denuncias
  for each row execute function public.feira_denuncia_antes();

-- ---------------------------------------------------------------------
-- Moderação (só admin; o admin é o mesmo do Habbo Music)
-- ---------------------------------------------------------------------
create or replace function public.feira_mod_print(p_id bigint, p_ok boolean, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.feira_anuncios set ok = p_ok, rejected = case when p_ok then null else coalesce(p_motivo, 'Print recusado') end where id = p_id;
end $$;

create or replace function public.feira_mod_remover(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.feira_anuncios set status = 'removido' where id = p_id;
  delete from public.feira_denuncias where anuncio_id = p_id;
end $$;

create or replace function public.feira_mod_ignorar(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  delete from public.feira_denuncias where id = p_id;
end $$;

-- o ban é o mesmo nos dois sites
create or replace function public.feira_mod_banir(p_user uuid, p_ban boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.profiles set banned = p_ban where id = p_user and not is_admin;
  if p_ban then
    update public.feira_anuncios set status = 'removido' where user_id = p_user;
    update public.anuncios set status = 'removido' where user_id = p_user;
  end if;
end $$;

create or replace function public.feira_mod_limite(p_user uuid, p_limite integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  update public.profiles set feira_limit = greatest(0, least(1000, p_limite)) where id = p_user;
end $$;

-- ---------------------------------------------------------------------
-- Contador de visitas da feira (só números por dia, como no Habbo Music)
-- ---------------------------------------------------------------------
create table if not exists public.feira_visitas (
  dia       date primary key,
  aberturas integer not null default 0,
  pessoas   integer not null default 0
);
create or replace function public.feira_registrar_visita(p_novo boolean)
returns void language plpgsql security definer set search_path = public as $$
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  insert into public.feira_visitas (dia, aberturas, pessoas) values (hoje, 1, case when p_novo then 1 else 0 end)
  on conflict (dia) do update set
    aberturas = public.feira_visitas.aberturas + 1,
    pessoas   = public.feira_visitas.pessoas + case when p_novo then 1 else 0 end;
end $$;
create or replace function public.feira_ver_visitas()
returns table (dia date, aberturas integer, pessoas integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só admin.'; end if;
  return query select v.dia, v.aberturas, v.pessoas from public.feira_visitas v
    where v.dia > (now() at time zone 'America/Sao_Paulo')::date - 60 order by v.dia desc;
end $$;

-- ---------------------------------------------------------------------
-- Regras de acesso (Row Level Security)
-- ---------------------------------------------------------------------
alter table public.feira_anuncios  enable row level security;
alter table public.feira_denuncias enable row level security;
alter table public.feira_visitas   enable row level security;
revoke all on public.feira_anuncios, public.feira_denuncias, public.feira_visitas from anon, authenticated;

-- anúncios: feira pública; cada um só mexe nos seus (status, preço, quantidade e observação)
grant select on public.feira_anuncios to anon, authenticated;
grant insert (tipo, nome, preco, qtd, nota, print_path) on public.feira_anuncios to authenticated;
grant update (status, preco, qtd, nota) on public.feira_anuncios to authenticated;
drop policy if exists feira_leitura on public.feira_anuncios;
create policy feira_leitura on public.feira_anuncios for select
  using (status <> 'removido' or user_id = auth.uid() or public.is_admin());
drop policy if exists feira_criar on public.feira_anuncios;
create policy feira_criar on public.feira_anuncios for insert to authenticated with check (user_id = auth.uid());
drop policy if exists feira_editar on public.feira_anuncios;
create policy feira_editar on public.feira_anuncios for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- denúncias: qualquer pessoa logada denuncia; só admin lê
grant insert (anuncio_id, motivo) on public.feira_denuncias to authenticated;
grant select on public.feira_denuncias to authenticated;
drop policy if exists feira_denuncias_criar on public.feira_denuncias;
create policy feira_denuncias_criar on public.feira_denuncias for insert to authenticated with check (reporter = auth.uid());
drop policy if exists feira_denuncias_admin on public.feira_denuncias;
create policy feira_denuncias_admin on public.feira_denuncias for select to authenticated using (public.is_admin());

-- visitas: ninguém acessa direto (só pelas funções)

revoke execute on function public.feira_meu_nick(text, text), public.feira_mod_print(bigint, boolean, text),
  public.feira_mod_remover(bigint), public.feira_mod_ignorar(bigint), public.feira_mod_banir(uuid, boolean),
  public.feira_mod_limite(uuid, integer), public.feira_ver_visitas(), public.feira_registrar_visita(boolean) from public, anon;
grant execute on function public.feira_meu_nick(text, text), public.feira_mod_print(bigint, boolean, text),
  public.feira_mod_remover(bigint), public.feira_mod_ignorar(bigint), public.feira_mod_banir(uuid, boolean),
  public.feira_mod_limite(uuid, integer), public.feira_ver_visitas() to authenticated;
grant execute on function public.feira_registrar_visita(boolean) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Prints da feira: só imagem, até 5 MB, cada pessoa na própria pasta, no máximo 50
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feira', 'feira', true, 5242880, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/png','image/jpeg','image/webp'];

create or replace function public.feira_meus_prints()
returns integer language sql stable security definer set search_path = public, storage as $$
  select count(*)::int from storage.objects
   where bucket_id = 'feira' and (storage.foldername(name))[1] = auth.uid()::text
$$;
revoke execute on function public.feira_meus_prints() from public, anon;
grant execute on function public.feira_meus_prints() to authenticated;

drop policy if exists feira_prints_enviar on storage.objects;
create policy feira_prints_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'feira' and (storage.foldername(name))[1] = auth.uid()::text and public.feira_meus_prints() < 50);
drop policy if exists feira_prints_apagar on storage.objects;
create policy feira_prints_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'feira' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists feira_prints_listar on storage.objects;
create policy feira_prints_listar on storage.objects for select to authenticated
  using (bucket_id = 'feira' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
