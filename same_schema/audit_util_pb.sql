define schema = scott
define tspace = users
define prefix = aud$

CREATE OR REPLACE PACKAGE BODY &&schema..&&prefix.AUDIT_UTIL
IS

  TYPE t_grantee_tab IS TABLE OF VARCHAR2(128);     
--
-- global vars for new audit table support
--
  g_aud_schema      constant varchar2(30)  := upper('&&schema');
  g_aud_tspace      constant varchar2(30)  := '&&tspace';
  
  -- prefix for all audit table names
  --
  g_aud_prefix      constant varchar2(10)  := upper('&&prefix.');
  
  -- 1= dbms_output, 2=maint table, 3=both
  --
  g_log_level       constant int           := 3;  
  
  -- by default, just updates/deletes
  --
  g_inserts_audited constant boolean       := false;  
  
  -- sometimes an update is really a logical deleted. If you set a column
  -- named as per below to 'Y', we'll audit it as a logical delete, not an update
  --
  g_logical_del_col constant varchar2(100) := 'DELETED_IND';  
  
  -- whether we want to capture OLD images for updates as well as NEW
  --
  g_capture_new_updates constant boolean := false;

  -- if you want an automated scheduler job to look at auto-renaming
  -- partitions, there is the name it gets
  --
  g_job_name     constant varchar2(80) := g_aud_prefix||'AUDIT_PARTITION_NAME_TIDY_UP';

  --
  -- where we should create the trigger (true=audit schema, false=table owning schema)
  --
  g_trigger_in_audit_schema constant boolean := true;

  --
  -- should we use partitioning
  --
  g_partitioning  constant boolean  := true;
  
  --
  -- should we use bulk binding (aka, are you expecting batch DML regularly)
  --
  g_bulk_bind constant boolean  := true;
  g_bulk_bind_limit    int      := 500;
  
  --
  -- should we use a context/WHEN clause or a plsql call for trigger maintenance
  --
  g_use_context constant boolean := true;
  
--
-- NOTE: In terms of other naming conventions, check the routines
--           audit_table_name
--           audit_package_name
--           audit_trigger_name
--       They are the single points for controlling naming standard for each audit object type
--

--
-- Optional:
--  If you want the audit tables to be queryable from certain schemas/rolers, you can add them
--  here.  
--
--   eg  g_table_grantees t_grantee_tab := t_grantee_tab('SCOTT','HR','SYSTEM');
-- 
  g_table_grantees t_grantee_tab := t_grantee_tab();
  
  ex_non_existent_user exception;
  pragma exception_init (ex_non_existent_user, -1917); -- non-existent user or role exception                          

-----------------------------------------------------------------------------
--
-- Internal routines 
--

--
-- Simple logger.  Be default we pretty much spew everything out to dbms_output
-- and to data_maint_log
--
procedure logger(p_msg   varchar2
                ,p_level number default g_log_level) is
begin
  dbms_application_info.set_client_info(p_msg);
  if bitand(p_level,1) = 1 then
     dbms_output.put_line(p_msg);
  end if;

  if bitand(p_level,2) = 2 then
    insert into &&prefix.maint_log ( maint_seq, tstamp, msg )
    values (&&prefix.maint_seq.nextval, systimestamp, substr(p_msg,1,4000));
    commit;

  end if;
end;

--
-- execute some DDL, as well as output it
--
procedure do_sql(p_sql varchar2,p_execute boolean) is
  l_sql varchar2(32767) := p_sql;
begin
  while instr(l_sql,chr(10)) > 0 loop
    dbms_output.put_line(substr(l_sql,1,instr(l_sql,chr(10))-1));
    l_sql := substr(l_sql,instr(l_sql,chr(10))+1);
  end loop;
  if l_sql is not null then
    dbms_output.put_line(l_sql);
  end if;

  if p_execute then
    execute immediate p_sql;
  end if;
end;

--
-- Common interface for fatal errors
--
procedure die(p_msg varchar2) is
begin
  raise_application_error(-20378,p_msg);
end;

function dup_cnt(p_table_name varchar2, p_owner varchar2) return number is
  l_dup_cnt int;
begin
  select count(*)
  into   l_dup_cnt
  from   all_tables
  where  table_name = upper(p_table_name)
  and    owner != g_aud_schema;

  return l_dup_cnt;
end;

function valid_schema(p_owner varchar2) return boolean is
  l_valid_cnt int;
begin
  select count(*)
  into   l_valid_cnt
  from   &&prefix.schema_list
  where  schema_name = upper(p_owner);

  return l_valid_cnt>0;
end;

--
-- single point for standard audit table name (typically same as <table>)
--
function audit_table_name(p_table_name varchar2, p_owner varchar2) return varchar2 is
begin
  --if dup_cnt(p_table_name,p_owner) = 1 then
    return g_aud_prefix||upper(substr(p_table_name,1,128-nvl(length(g_aud_prefix),0)));
  --else
  --  return g_aud_prefix||substr(upper(substr(p_table_name,1,120-nvl(length(g_aud_prefix),0)))||'_'||upper(p_owner),1,120);
  --end if;
end;

--
-- single point for standard audit table name (typically "PKG_"<table>)
--
function audit_package_name(p_table_name varchar2, p_owner varchar2) return varchar2 is
begin
  --if dup_cnt(p_table_name,p_owner) = 1 then
    return g_aud_prefix||'PKG_'||upper(substr(p_table_name,1,120));
  --else
  --  return g_aud_prefix||'PKG_'||upper(substr(p_table_name,1,90))||'_'||upper(p_owner);
  --end if;
end;

--
-- single point for standard audit trigger name (typically "AUD$"<table>)
--
function audit_trigger_name(p_table_name varchar2, p_owner varchar2) return varchar2 is
begin
--  if dup_cnt(p_table_name,p_owner) = 1 then
--    return g_aud_prefix||upper(substr(p_table_name,1,120));
--  else
--    return g_aud_prefix||upper(substr(p_table_name,1,90))||'_'||upper(p_owner);
    return g_aud_prefix||upper(substr(p_table_name,1,120));
--  end if;
end;

--
-- Return a shortened name for the table for use
--
function table_pk_name(p_table_name varchar2, p_owner varchar2) return varchar2 is
begin
  if dup_cnt(p_table_name,p_owner) = 1 then
    return g_aud_prefix||upper(substr(p_table_name,1,125-nvl(length(g_aud_prefix),0)));
  else
    return g_aud_prefix||substr(upper(substr(p_table_name,1,120-nvl(length(g_aud_prefix),0)))||'_'||upper(p_owner),1,120);
  end if;
end;

--
-- Return a shortened name for the table for use with partitions
--
function table_par_name(p_table_name varchar2) return varchar2 is
begin
  return upper(substr(p_table_name,1,100));
end;


--
-- internal grant routines
--
procedure grant_table_access(p_table_name varchar2
                            ,p_owner varchar2
                            ,p_execute boolean) is
begin
  if g_table_grantees.count > 0 then
    for i IN g_table_grantees.FIRST..g_table_grantees.LAST
    loop
       -- block to catch and suppress grant exceptions
       begin
          do_sql('grant select on '||g_aud_schema||'.'||p_table_name||' to '||g_table_grantees(i),p_execute);
       exception 
          when ex_non_existent_user then
             logger ('grant select on '||g_aud_schema||'.'||p_table_name||' to ' || g_table_grantees(i) || ' failed'); -- just log and ignore the grant attempt
       end;
    end loop;
  end if;    
end;

procedure grant_package_access(p_package_name varchar2
                              ,p_owner varchar2
                              ,p_execute boolean) is
begin
  do_sql('grant execute on '||g_aud_schema||'.'||p_package_name||' to '||p_owner,p_execute);
exception 
  when ex_non_existent_user then
     logger ('grant execute on '||g_aud_schema||'.'||p_package_name||' to ' || p_owner || ' failed'); -- just log and ignore the grant attempt
end;

--
-- plus some grant exposure to the public
--
PROCEDURE grant_audit_access(p_object_name varchar2
                            ,p_owner varchar2
                            ,p_action varchar2) is
  l_object_name varchar2(200) := regexp_replace(upper(p_object_name),'^'||g_aud_schema||'\.');
BEGIN
  --
  -- just package asked for
  --
  if l_object_name like 'PKG%' then
    grant_package_access(l_object_name,p_owner,upper(p_action)='EXECUTE');
  elsif (g_aud_prefix is null or substr(l_object_name,1,length(g_aud_prefix)) = g_aud_prefix ) then
    --
    -- otherwise the whole lot for tables eg AUD_MY_TABLE...
    --
    grant_table_access(l_object_name,p_owner,upper(p_action)='EXECUTE');
    grant_package_access(
       audit_package_name(
           case when g_aud_prefix is not null then regexp_replace(l_object_name,'^'||g_aud_prefix) else l_object_name end
           ,p_owner),
         p_owner,
         upper(p_action)='EXECUTE');
  else
    --
    -- maybe they left off the AUD_ prefix
    --
    grant_table_access(audit_table_name(l_object_name,p_owner),p_owner,upper(p_action)='EXECUTE');
    grant_package_access(audit_package_name(l_object_name,p_owner),p_owner,upper(p_action)='EXECUTE');
  end if;
END;


--
-- See if audit table already exists, if not, create it
--
procedure initial_aud_tab_existence(p_owner varchar2
                                   ,p_table_name varchar2
                                   ,p_created out boolean
                                   ,p_execute boolean) is
  l_audit_table_name varchar2(140) := audit_table_name(p_table_name,p_owner);
  l_table_par        varchar2(140) := table_par_name(p_table_name);
  l_table_pk         varchar2(140) := table_pk_name(p_table_name,p_owner);
  --
  -- first range partition name/boundary
  --
  l_partition1       varchar2(128) := l_table_par||'_p'||to_char(trunc(add_months(sysdate,1),'MM'),'YYYYMM');
  l_boundary1        varchar2(12) := to_char(trunc(add_months(sysdate,2),'MM'),'YYYYMMDD');
  x number;
begin
  --
  -- first check for table
  --
  begin
    select 1
    into   x
    from   dual
    where not exists (
      select 1
      from   all_tables
      where  owner = g_aud_schema
      and    table_name = l_audit_table_name
      );

    do_sql('create table '||g_aud_schema||'.'||l_audit_table_name||' ( '||chr(10)||
           ' aud$tstamp     timestamp   not null, '||chr(10)||
           ' aud$id         number(18)  not null, '||chr(10)||
           ' aud$image      varchar2(3) not null ) '||chr(10)||
           case when g_partitioning then
             ' partition by range ( aud$tstamp  ) '||chr(10)||
             ' interval (numtoyminterval(1,''MONTH'')) '||chr(10)||
             ' ( partition '||l_partition1||' values less than ( to_timestamp('''||l_boundary1||''',''yyyymmdd'') )'||chr(10)||
             ' ) ' 
           end ||
           ' pctfree 1 tablespace '||g_aud_tspace, p_execute);

    p_created := true;
    grant_table_access(l_audit_table_name,p_owner,p_execute);
  exception
    when no_data_found then
      p_created := false;
  end;

  --
  -- then add a primary key if its not there
  --
  begin
    select 1
    into   x
    from   dual
    where not exists (
      select 1
      from   all_constraints
      where  owner = g_aud_schema
      and    table_name = l_audit_table_name
      and    constraint_type = 'P'
      );

    do_sql('alter table '||g_aud_schema||'.'||l_audit_table_name||chr(10)||
           '  add constraint '||l_table_pk||'_PK primary key ( aud$tstamp, aud$id, aud$image) '||chr(10)||
           '  using index'||chr(10)||
           '    (create unique index '||g_aud_schema||'.'||l_table_pk||'_PK'||chr(10)||
           '     on '||g_aud_schema||'.'||l_audit_table_name||' ( aud$tstamp, aud$id, aud$image) '||chr(10)||
           '     '||case when g_partitioning then 'local ' end||
           ' tablespace '||g_aud_tspace||')',p_execute);
  exception
    when no_data_found then
      null;
  end;

end;

--
-- See if columns have been added. If so, add them to the audit table
--
procedure add_new_cols(p_owner varchar2
                      ,p_table_name varchar2
                      ,p_altered out boolean
                      ,p_execute boolean) is
  l_audit_table_name varchar2(128) := audit_table_name(p_table_name,p_owner);
  col_clause varchar2(1000);
  already_there exception;
    pragma exception_init(already_there,-01430);
begin
  p_altered := false;
  for cols in ( select c.column_name,
                       c.data_type,
                       c.data_precision,
                       c.data_scale,
                       c.data_type_owner,
                       c.data_length,
                       c.column_id,
                       a.data_type  aud_data_type,
                       a.data_precision aud_data_precision,
                       a.data_scale aud_data_scale,
                       a.data_type_owner aud_data_type_owner,
                       a.data_length aud_data_length
                from   ( select *
                         from   all_tab_columns
                         where  owner = p_owner
                         and    table_name = p_table_name ) c,
                       ( select *
                         from all_tab_columns
                         where owner = g_aud_schema
                         and   table_name = l_audit_table_name ) a
                where  c.column_name = a.column_name(+)
                order by c.column_id
                ) loop

     col_clause := null;
     --
     -- new columns
     --
     if cols.aud_data_type is null then
       if regexp_replace(cols.data_type,'\(.*\)') in ('CLOB','NCLOB','DATE','TIMESTAMP','ROWID',
                                                      'BLOB','INTERVAL DAY','INTERVAL YEAR TO MONTH',
                                                      'TIMESTAMP WITH TIME ZONE','TIMESTAMP WITH LOCAL TIME ZONE') 
       then
           col_clause := 'add '||cols.column_name||' '||cols.data_type;
       elsif cols.data_type in ('RAW','CHAR','VARCHAR2','NCHAR','NVARCHAR2') then
           col_clause := 'add '||cols.column_name||' '||cols.data_type||'('||cols.data_length||')';
       elsif (cols.data_type in ('NUMBER') and cols.data_precision is not null) then
           col_clause := 'add '||cols.column_name||' '||cols.data_type||'('||cols.data_precision||','||cols.data_scale||')';
       elsif cols.data_type in ('FLOAT') then
           if cols.data_precision < 126 then
             col_clause := 'add '||cols.column_name||' '||cols.data_type||'('||cols.data_precision||')';
           else
             col_clause := 'add '||cols.column_name||' '||cols.data_type;
           end if;
       elsif (cols.data_type in ('NUMBER','BINARY_DOUBLE','BINARY_FLOAT','FLOAT') and cols.data_precision is null) then
           col_clause := 'add '||cols.column_name||' '||cols.data_type;
       elsif cols.data_type_owner is not null  then
           if cols.data_type_owner = 'PUBLIC' then
             col_clause := 'add '||cols.column_name||' '||cols.data_type;
           else
             col_clause := 'add '||cols.column_name||' '||cols.data_type_owner||'.'||cols.data_type;
           end if;
       else
         die('Spat the dummy with data type '||cols.data_type||' for '||cols.column_name);
       end if;
     else
     --
     -- existing columns (try to issue a MODIFY, eg increase size etc)
     --
       if cols.data_type in ('CLOB','DATE','ROWID','BLOB','LONG') then
           null; -- no change
       elsif cols.data_type like 'TIMESTAMP%' then
           if cols.data_scale = cols.aud_data_scale then
              null; -- no change
           elsif cols.data_scale > cols.aud_data_scale then
              col_clause := 'modify '||cols.column_name||' '||cols.data_type;
           else
              die('Spat the dummy with precision reduction on '||cols.column_name);
           end if;
       elsif cols.data_type in ('RAW','CHAR','VARCHAR2') then
           if cols.data_length = cols.aud_data_length then
              null; -- no change
           elsif cols.data_length > cols.aud_data_length then
              col_clause := 'modify '||cols.column_name||' '||cols.data_type||'('||cols.data_length||')';
           else
              die('Spat the dummy with precision reduction on '||cols.column_name);
           end if;
       elsif cols.data_type in ('INTERVAL DAY','INTERVAL YEAR') then
           if cols.data_precision = cols.data_precision and cols.data_scale = cols.data_scale then
              null; -- no change
           elsif cols.data_precision >= cols.data_precision and cols.data_scale >= cols.data_scale then
              col_clause := 'modify '||cols.column_name||' '||cols.data_type||'('||cols.data_precision||') TO '||
                             CASE WHEN cols.data_type = 'INTERVAL DAY' THEN 'SECOND' ELSE 'MONTH' END||'('||cols.data_scale||')';
           else
              die('Spat the dummy with precision reduction on '||cols.column_name);
           end if;
       elsif cols.data_type in ('NUMBER') then
           -- this is merely a "best guess" with number - all sorts of permutations possible
           -- with precision and scale.  We'll just work with precision and see what happens when
           -- we try to alter the table
           --
           if nvl(cols.data_precision,-1) = nvl(cols.aud_data_precision,-1) and
              nvl(cols.data_scale,-1) = nvl(cols.aud_data_scale,-1) then
              null; -- no change
           elsif cols.data_precision > cols.aud_data_precision then
              col_clause := 'modify '||cols.column_name||' '||cols.data_type||'('||cols.data_precision||','||cols.data_scale||')';
           else
              die('Spat the dummy with precision reduction on '||cols.column_name);
           end if;
       elsif cols.data_type != cols.aud_data_type then
         die('Spat the dummy with data type change for '||cols.column_name);
       end if;
     end if;

     if col_clause is not null then
       begin
         do_sql('alter table '||g_aud_schema||'.'||l_audit_table_name||' '||col_clause,p_execute);
         p_altered := true;
       exception
          when already_there then null;
       end;
     end if;
  end loop;

  --
  -- any dropped columns means recreate package / trigger
  --
  for i in ( select column_name
             from all_tab_columns
             where owner = g_aud_schema
             and   table_name = l_audit_table_name
             minus
             select column_name
             from   all_tab_columns
             where  owner = p_owner
             and    table_name = p_table_name ) loop
    p_altered := true;
    exit;
  end loop;

end;


-- =========================================================================
--
--  main public routines, most just permutations of the above routines
--


--
--  create or alter an audit table, with flags as to what has happened
--
PROCEDURE generate_audit_table(p_owner varchar2
                              ,p_table_name varchar2
                              ,p_created out boolean
                              ,p_altered out boolean
                              ,p_action varchar2) is
BEGIN
  logger('Call to generate audit table for '||p_owner||'.'||p_table_name);
  
  if not valid_schema(p_owner) then
    die('You can only manage audit facilities for schemas listed in '||upper('&prefix.')||'SCHEMA_LIST');
  end if;
  
  initial_aud_tab_existence(p_owner,p_table_name,p_created,upper(p_action)='EXECUTE');
  add_new_cols(p_owner,p_table_name,p_altered,upper(p_action)='EXECUTE');
END;

--
--  create or alter an audit table, ignore flags
--
PROCEDURE generate_audit_table(p_owner varchar2
                              ,p_table_name varchar2
                              ,p_action varchar2) is
  l_created boolean;
  l_altered boolean;
BEGIN
  generate_audit_table(p_owner
                      ,p_table_name
                      ,l_created
                      ,l_altered
                      ,p_action);
END;


--
-- generate audit row package (generated package is called exclusively from within audit triggers)
--
PROCEDURE generate_audit_package(p_owner varchar2
                                ,p_table_name varchar2
                                ,p_action varchar2) is
  cursor col_defn is
    select column_name,
           data_type,
           max(length(column_name)) over () as maxlen
    from   all_tab_columns
    where  owner = p_owner
    and    table_name = p_table_name
    order  by column_id;

  type col_list is table of col_defn%rowtype;
  cols col_list;

  l_ddl   varchar2(32767);

  procedure bld(p_sql varchar2) is
  begin
     l_ddl := l_ddl || p_sql || chr(10);
  end;

BEGIN
  logger('Call to generate audit package for '||p_owner||'.'||p_table_name);

  if not valid_schema(p_owner) then
    die('You can only manage audit facilities for schemas listed in '||upper('&prefix.')||'SCHEMA_LIST');
  end if;

  open col_defn;
  fetch col_defn
  bulk collect into cols;
  close col_defn;

  bld('create or replace');
  bld('package '||g_aud_schema||'.'||audit_package_name(p_table_name,p_owner)||' is');

  bld(' ');
  bld(' /***************************************************************/');
  bld(' /* ATTENTION                                                   */');
  bld(' /*                                                             */');
  bld(' /* This package is automatically generated by audit generator  */');
  bld(' /* utility.  Do not edit this package by hand as your changes  */');
  bld(' /* will be lost if the package are re-generated.               */');
  bld(' /***************************************************************/');

  if g_bulk_bind then
    bld(' ');
    bld('  procedure bulk_init;');
    bld('  procedure bulk_process;');
  end if;

  bld(' ');
  bld('  procedure audit_row(');
  bld('     p_aud$tstamp                     timestamp');
  bld('    ,p_aud$id                         number');
  bld('    ,p_aud$image                      varchar2');

  for i in 1 .. cols.count loop
     -- intervals are different...
     if (cols(i).data_type like 'INTERVAL DAY%') then
        bld('    ,p_'||rpad(substr(lower(cols(i).column_name),1,110),cols(i).maxlen+2)||''||'dsinterval_unconstrained');
     elsif (cols(i).data_type like 'INTERVAL YEAR%') then
        bld('    ,p_'||rpad(substr(lower(cols(i).column_name),1,110),cols(i).maxlen+2)||''||'yminterval_unconstrained');
     else
        bld('    ,p_'||rpad(substr(lower(cols(i).column_name),1,110),cols(i).maxlen+2)||''||lower(regexp_replace(cols(i).data_type,'\(.*\)')));
     end if;
  end loop;

  bld('  );');
  bld('end;');
  do_sql(l_ddl,upper(p_action)='EXECUTE');

  l_ddl := null;

  bld('create or replace');
  bld('package body '||g_aud_schema||'.'||audit_package_name(p_table_name,p_owner)||' is');
  bld(' ');
  bld(' /***************************************************************/');
  bld(' /* ATTENTION                                                   */');
  bld(' /*                                                             */');
  bld(' /* This package is automatically generated by audit generator  */');
  bld(' /* utility.  Do not edit this package by hand as your changes  */');
  bld(' /* will be lost if the package are re-generated.               */');
  bld(' /***************************************************************/');
  bld(' ');

  if g_bulk_bind then
    bld('    type t_audit_rows is table of '||g_aud_schema||'.'||audit_table_name(p_table_name,p_owner)||'%rowtype');
    bld('      index by pls_integer;');
    bld(' ');
    bld('    l_audrows t_audit_rows;');
    bld(' ');
    bld('  procedure bulk_init is');
    bld('  begin');
    bld('    l_audrows.delete;');
    bld('  end;');
    bld(' ');
    bld('  procedure bulk_process is');
    bld('  begin');
    bld('    forall i in 1 .. l_audrows.count');
    bld('      insert into '||g_aud_schema||'.'||audit_table_name(p_table_name,p_owner)||' values l_audrows(i);');
    bld('    bulk_init;');
    bld('  end;');
    bld(' ');
  end if;

  bld('  procedure audit_row(');
  bld('     p_aud$tstamp                    timestamp');
  bld('    ,p_aud$id                        number');
  bld('    ,p_aud$image                     varchar2');

  for i in 1 .. cols.count loop
     -- intervals are different...
     if (cols(i).data_type like 'INTERVAL DAY%') then
        bld('    ,p_'||rpad(substr(lower(cols(i).column_name),1,110),cols(i).maxlen+2)||''||'dsinterval_unconstrained');
     elsif (cols(i).data_type like 'INTERVAL YEAR%') then
        bld('    ,p_'||rpad(substr(lower(cols(i).column_name),1,110),cols(i).maxlen+2)||''||'yminterval_unconstrained');
     else
        bld('    ,p_'||rpad(substr(lower(cols(i).column_name),1,110),cols(i).maxlen+2)||''||lower(regexp_replace(cols(i).data_type,'\(.*\)')));
     end if;
  end loop;

  bld('  ) is');

  if g_bulk_bind then
    bld('    l_idx pls_integer := l_audrows.count+1;');
  end if;

  bld('  begin');
  bld('');

  if g_bulk_bind then

    bld('    if l_idx > '||g_bulk_bind_limit||' then');
    bld('      bulk_process;');
    bld('      l_idx := 1;');
    bld('    end if;');
    bld(' ');
    bld('    l_audrows(l_idx).aud$tstamp := p_aud$tstamp;');
    bld('    l_audrows(l_idx).aud$id     := p_aud$id;');
    bld('    l_audrows(l_idx).aud$image  := p_aud$image;');

    for i in 1 .. cols.count loop
      bld('    l_audrows(l_idx).'||rpad(lower(cols(i).column_name),cols(i).maxlen+2)||' := p_'||lower(cols(i).column_name)||';');
    end loop;

  else
    bld('  insert into '||g_aud_schema||'.'||audit_table_name(p_table_name,p_owner)||' (');
    bld('     aud$tstamp');
    bld('    ,aud$id');
    bld('    ,aud$image');

    for i in 1 .. cols.count loop
      bld('    ,'||lower(cols(i).column_name));
    end loop;

    bld('  ) values (');
    bld('     p_aud$tstamp');
    bld('    ,p_aud$id');
    bld('    ,p_aud$image');

    for i in 1 .. cols.count loop
      bld('    ,p_'||substr(lower(cols(i).column_name),1,110));
    end loop;

    bld('    );');
  end if;
  
  bld('  end;');
  bld('');
  bld('end;');
  do_sql(l_ddl,upper(p_action)='EXECUTE');

  grant_package_access(audit_package_name(p_table_name,p_owner),p_owner,upper(p_action)='EXECUTE');

END;

--
-- generate audit row trigger
--
PROCEDURE generate_audit_trigger(p_owner varchar2
                                ,p_table_name varchar2
                                ,p_action varchar2
                                ,p_update_cols varchar2 default null
                                ,p_when_clause varchar2 default null
                                ,p_enable_trigger boolean default true) is
  cursor col_defn is
    select column_name,
           data_type,
           max(length(column_name)) over () as maxlen,
           max(case when column_name = g_logical_del_col then lower(column_name) end) over () as logdel
    from   all_tab_columns
    where  owner = p_owner
    and    table_name = p_table_name
    order  by column_id;

  type col_list is table of col_defn%rowtype;
  cols col_list;

  l_ddl   varchar2(32767);
  l_update_expr varchar2(4000);
  l_update_cols varchar2(4000) := upper(rtrim(p_update_cols,','))||',';
  l_when_clause varchar2(4000) := p_when_clause;
  l_col_name    varchar2(128);
  l_col_valid   boolean;
  l_audit_trigger_name varchar2(128) := audit_trigger_name(p_table_name,p_owner);

  procedure bld(p_sql varchar2) is
  begin
     l_ddl := l_ddl || p_sql || chr(10);
  end;

  procedure add_cols(p_new_or_old varchar2) is
  begin
    for i in 1 .. cols.count loop
       bld('        ,p_'||rpad(substr(lower(cols(i).column_name),1,110),cols(i).maxlen+2)||'=>:'||p_new_or_old||'.'||lower(cols(i).column_name));
    end loop;
    bld('        );');
  end;

BEGIN
  logger('Call to generate audit trigger for '||p_owner||'.'||p_table_name);

  if not valid_schema(p_owner) then
    die('You can only manage audit facilities for schemas listed in '||upper('&prefix.')||'SCHEMA_LIST');
  end if;


  if p_update_cols is null then
    begin
      select upper(rtrim(update_cols,','))||','
      into   l_update_cols
      from   &&prefix.audit_util_update_trig
      where  table_name   = upper(p_table_name);
    exception
      when no_data_found then
        l_update_cols := null;
    end;
  elsif upper(p_update_cols) = 'NULL' then
     update &&prefix.audit_util_update_trig
     set    update_cols  = null
     where  table_name   = upper(p_table_name);
     l_update_cols := null;
  else
    begin
      insert into &&prefix.audit_util_update_trig (table_name,update_cols)
      values ( upper(p_table_name),upper(p_update_cols) );
    exception
      when dup_val_on_index then
         update &&prefix.audit_util_update_trig
         set    update_cols  = upper(p_update_cols)
         where  ( update_cols != upper(p_update_cols) or update_cols is null )
         and    table_name   = upper(p_table_name);
    end;
    l_update_cols := upper(rtrim(p_update_cols,','))||',';
  end if;


  if p_when_clause is null then
    begin
      select when_clause
      into   l_when_clause
      from   &&prefix.audit_util_update_trig
      where  table_name   = upper(p_table_name);
    exception
      when no_data_found then
        l_when_clause := null;
    end;
  elsif upper(p_when_clause) = 'NULL' then
    update &&prefix.audit_util_update_trig
    set    when_clause  = null
    where  table_name   = upper(p_table_name);
    l_when_clause := null;
  else
    l_when_clause := p_when_clause;
    if upper(l_when_clause) not like 'WHEN%' then
      l_when_clause := 'when ('||l_when_clause||')';
    end if;
    begin
      insert into &&prefix.audit_util_update_trig (table_name, when_clause)
      values ( upper(p_table_name),l_when_clause );
    exception
      when dup_val_on_index then
         update &&prefix.audit_util_update_trig
         set    when_clause  = l_when_clause
         where  ( when_clause != l_when_clause or when_clause is null )
         and    table_name   = upper(p_table_name);
    end;
  end if;

  --
  -- strip off the WHEN to append context if needed
  --
  if g_use_context then
    l_when_clause := 'when ('||substr(l_when_clause,5)||
                     case when l_when_clause is not null then ' and' end||
                     ' sys_context(''TRIGGER_CTL'','''||l_audit_trigger_name||''') is null)';
  end if;

  open col_defn;
  fetch col_defn
  bulk collect into cols;
  close col_defn;

  while instr(l_update_cols,',') > 1 loop
    l_col_name := substr(l_update_cols,1,instr( l_update_cols,',')-1);
    l_col_valid := false;
    for i in 1 .. cols.count loop
       l_col_valid := l_col_valid or cols(i).column_name = l_col_name;
    end loop;
    if not l_col_valid then
       die(l_col_name||' is not valid');
    end if;
    l_update_expr := l_update_expr ||
         case when l_update_expr is not null then '     ' end ||
         rpad('updating('''||l_col_name||''') ',cols(1).maxlen+12)||' or '||chr(10);
    l_update_cols := substr(l_update_cols,instr( l_update_cols,',')+1);
  end loop;

  if l_update_expr is null then
     l_update_expr := 'updating or'||chr(10);
  end if;

  bld('create or replace');
  bld('trigger '||
      case when g_trigger_in_audit_schema then g_aud_schema else upper(p_owner) end
      ||'.'||l_audit_trigger_name);
      
  if g_bulk_bind then      
    bld('for insert or update or delete on '||p_owner||'.'||p_table_name);
    bld('disable');
    if l_when_clause is not null then
       bld(l_when_clause);
    end if;
    bld('compound trigger');
  else
    if g_inserts_audited then
      bld('after insert or update or delete on '||p_owner||'.'||p_table_name);
    else
      bld('after update or delete on '||p_owner||'.'||p_table_name);
    end if;
    bld('for each row');
    bld('disable');
    if l_when_clause is not null then
       bld(l_when_clause);
    end if;
    bld('declare');
  end if;
  bld(' l_dml       varchar2(1) := case when updating then ''U'' when inserting then ''I'' else ''D'' end;');
  bld(' l_tstamp    timestamp;');
  bld(' l_id        number;');
  bld(' l_descr     varchar2(100);');

  bld(' ');
  bld(' /***************************************************************/');
  bld(' /* ATTENTION                                                   */');
  bld(' /*                                                             */');
  bld(' /* This package is automatically generated by audit generator  */');
  bld(' /* utility.  Do not edit this package by hand as your changes  */');
  bld(' /* will be lost if the package are re-generated.               */');
  bld(' /***************************************************************/');
  bld(' ');

  if g_bulk_bind then      
    bld('before statement is');
    bld('begin');
    if not g_use_context then
      bld(' if '||lower(g_aud_schema)||'.trigger_ctl.enabled('''||l_audit_trigger_name||''') then');
    end if;
    bld('   '||lower(g_aud_schema||'.'||audit_package_name(p_table_name,p_owner))||'.bulk_init;');
    if not g_use_context then
      bld(' end if;');
    end if;
    bld('end before statement;');
    bld(' ');
    bld('after each row is');
  end if;
  
  bld('begin');
  if not g_use_context then
    bld(' if '||lower(g_aud_schema)||'.trigger_ctl.enabled('''||l_audit_trigger_name||''') then');
  end if;
  
  bld('  l_descr := ');
  bld('    case ');
  if cols(1).logdel is not null then
    bld('      when :new.'||cols(1).logdel||' = ''Y'' and :old.'||cols(1).logdel||' = ''N'' ');
    bld('        then ''LOGICALLY DELETED''');
  end if;

  bld('      when updating');
  bld('        then ''UPDATE''');
  bld('      when inserting');
  bld('        then ''INSERT''');
  bld('      else');
  bld('        ''DELETE''');
  bld('    end;');

  bld(' ');
  if g_bulk_bind then      
    bld('  '||lower(g_aud_schema)||'.&&prefix.audit_pkg.log_header_bulk('''||upper(p_table_name)||''',l_dml,l_descr,l_tstamp,l_id);');
  else
    bld('  '||lower(g_aud_schema)||'.&&prefix.audit_pkg.log_header('''||upper(p_table_name)||''',l_dml,l_descr,l_tstamp,l_id);');
  end if;
  bld(' ');

  bld('  if '||l_update_expr||'     deleting then ');

  bld('     '||lower(g_aud_schema||'.'||audit_package_name(p_table_name,p_owner))||'.audit_row(');
  bld('         p_aud$tstamp'||lpad('=>',greatest(cols(1).maxlen-6,3))||'l_tstamp');
  bld('        ,p_aud$id    '||lpad('=>',greatest(cols(1).maxlen-6,3))||'l_id');
  bld('        ,p_aud$image '||lpad('=>',greatest(cols(1).maxlen-6,3))||'''OLD''');
  add_cols('old');
  bld('  end if;');

  if g_capture_new_updates or g_inserts_audited then
    if g_capture_new_updates and g_inserts_audited then
      bld('  if '||l_update_expr||'     inserting then ');
    elsif not g_capture_new_updates and g_inserts_audited then
      bld('  if inserting then ');
    elsif g_capture_new_updates and not g_inserts_audited then
      bld('  if '||substr(l_update_expr,1,length(l_update_expr)-3)||' then ');
    end if;
    
    bld('     '||lower(g_aud_schema||'.'||audit_package_name(p_table_name,p_owner))||'.audit_row(');
    bld('         p_aud$tstamp'||lpad('=>',greatest(cols(1).maxlen-6,3))||'l_tstamp');
    bld('        ,p_aud$id    '||lpad('=>',greatest(cols(1).maxlen-6,3))||'l_id');
    bld('        ,p_aud$image '||lpad('=>',greatest(cols(1).maxlen-6,3))||'''NEW''');
    add_cols('new');
    bld('  end if;');
  end if;

  if not g_use_context then
    bld(' end if;');
  end if;

  if g_bulk_bind then   
    bld('end after each row;');
    bld(' ');
    bld('after statement is');
    bld('begin');
    if not g_use_context then
      bld(' if '||lower(g_aud_schema)||'.&&prefix.trigger_ctl.enabled('''||l_audit_trigger_name||''') then');
    end if;
    bld('   -- log the headers');
    bld('   '||lower(g_aud_schema)||'.&&prefix.audit_pkg.bulk_process;');
    bld('   -- log the details');
    bld('   '||lower(g_aud_schema||'.'||audit_package_name(p_table_name,p_owner))||'.bulk_process;');
    if not g_use_context then
      bld(' end if;');
    end if;
    bld('end after statement;');
  end if;
  bld('end;');
  
  do_sql(l_ddl,upper(p_action)='EXECUTE');

  if p_enable_trigger then
    do_sql('alter trigger '||case when g_trigger_in_audit_schema then g_aud_schema else upper(p_owner) end||'.'||
                  l_audit_trigger_name||' enable',upper(p_action)='EXECUTE');
  end if;

END;

--
-- generate all the audit stuff I need for a table
--
PROCEDURE generate_audit_support(p_owner varchar2
                                ,p_table_name varchar2
                                ,p_force boolean default false
                                ,p_action varchar2
                                ,p_update_cols varchar2 default null
                                ,p_when_clause varchar2 default null
                                ,p_enable_trigger boolean default true) is
  l_created boolean;
  l_altered boolean;
BEGIN
  generate_audit_table(p_owner,p_table_name,l_created,l_altered,p_action);
  if l_created or l_altered or p_force then
    generate_audit_package(p_owner,p_table_name,p_action);
    generate_audit_trigger(p_owner,p_table_name,p_action,p_update_cols,p_when_clause,p_enable_trigger);
  end if;
END;

--
-- Drop an audit table (we double check to see if its empty)
--
PROCEDURE drop_audit_table(p_owner varchar2
                          ,p_table_name varchar2
                          ,p_force boolean default false
                          ,p_action varchar2) is
  l_audit_table_name varchar2(60) := audit_table_name(p_table_name,p_owner);
  l_warning int;
BEGIN
  logger('Call to drop audit table for '||p_owner||'.'||p_table_name);

  if not valid_schema(p_owner) and not p_force then
    die('You can only manage audit facilities for schemas listed in '||upper('&prefix.')||'SCHEMA_LIST');
  end if;

  select 1
  into   l_warning
  from   all_tables
  where  owner = g_aud_schema
  and    table_name = l_audit_table_name;

  execute immediate
    'select count(*) from '||g_aud_schema||'.'||l_audit_table_name||' where rownum = 1'
    into l_warning;

  if l_warning > 0 and not p_force then
     die('Rows found in '||g_aud_schema||'.'||l_audit_table_name||'.  Use FORCE option if you really want to drop this');
  end if;
  do_sql('drop table '||g_aud_schema||'.'||l_audit_table_name,upper(p_action)='EXECUTE');

EXCEPTION
    when no_data_found then
       logger('INFO: No table '||g_aud_schema||'.'||l_audit_table_name||' was found');
END;

--
-- Drop an audit package
--
PROCEDURE drop_audit_package(p_owner varchar2
                            ,p_table_name varchar2
                            ,p_force boolean default false
                            ,p_action varchar2) is
BEGIN
  logger('Call to drop audit package for '||p_owner||'.'||p_table_name);

  if not valid_schema(p_owner) and not p_force then
    die('You can only manage audit facilities for schemas listed in '||upper('&prefix.')||'SCHEMA_LIST');
  end if;
  
  do_sql('drop package '||g_aud_schema||'.'||audit_package_name(p_table_name,p_owner),upper(p_action)='EXECUTE');
EXCEPTION
  when others then
    if sqlcode = -4043 then
      logger('INFO: Package was not found');
    else
      if sqlcode != -4043 or not p_force then   -- not found
        raise;
      end if;
    end if;
END;

--
-- Drop an audit trigger
--
PROCEDURE drop_audit_trigger(p_owner varchar2
                            ,p_table_name varchar2
                            ,p_force boolean default false
                            ,p_action varchar2) is
BEGIN
  logger('Call to drop audit trigger for '||p_owner||'.'||p_table_name);

  if not valid_schema(p_owner) and not p_force then
    die('You can only manage audit facilities for schemas listed in '||upper('&prefix.')||'SCHEMA_LIST');
  end if;
  
  do_sql('drop trigger '||case when g_trigger_in_audit_schema then g_aud_schema else upper(p_owner) end||'.'||audit_trigger_name(p_table_name,p_owner),upper(p_action)='EXECUTE');
EXCEPTION
  when others then
    if sqlcode = -4080 then
      logger('INFO: Trigger was not found');
    else
      if sqlcode != -4080 or not p_force then   -- not found
        raise;
      end if;
    end if;
END;

--
-- and a overload to do the lot
--

PROCEDURE drop_audit_support(p_owner varchar2
                            ,p_table_name varchar2
                            ,p_force boolean default false
                            ,p_action varchar2) is
BEGIN
  drop_audit_trigger(p_owner,p_table_name,p_force,p_action);
  drop_audit_package(p_owner,p_table_name,p_force,p_action);
  drop_audit_table(p_owner,p_table_name,p_force,p_action);
END;

PROCEDURE partition_name_tidy_up(p_operation varchar2 default 'DEFAULT',
                                 p_action varchar2) IS
  l_stamp_clause varchar2(200);
  l_new_parname  varchar2(200);

  l_dummy int;

  procedure new_job is
  begin
    logger('Scheduling partition name tidy up job');
    dbms_scheduler.create_job (
       job_name           =>  g_job_name,
       job_type           =>  'PLSQL_BLOCK',
       job_action         =>  lower(g_aud_schema)||'.&&prefix.audit_util.partition_name_tidy_up(p_action=>''EXECUTE'');',
       start_date         =>  trunc(sysdate)+1+9/24,
       repeat_interval    =>  'FREQ=DAILY; INTERVAL=1',
       enabled            =>  true,
       comments           =>  'Audit util partition renamer');
  end;

BEGIN
  if upper(p_operation) != 'DEFAULT' and nvl(upper(p_action),'x') != 'EXECUTE' then
    die('Only action=EXECUTE is permitted for non-default operations');
  end if;

  logger('Partition tidy up, operation='||p_operation);
  if upper(p_operation) = 'DISABLE' then
    dbms_scheduler.disable(g_job_name);
  elsif upper(p_operation) = 'ENABLE' then
    dbms_scheduler.enable(g_job_name);
  elsif upper(p_operation) = 'UNSCHEDULE' then
    dbms_scheduler.drop_job(g_job_name, force=>true);
  elsif upper(p_operation) = 'SCHEDULE' then
    new_job;
  elsif upper(p_operation) = 'CHECK' then
    begin
      select 1
      into   l_dummy
      from   all_scheduler_jobs
      where  job_name = g_job_name
      and    owner = g_aud_schema;
    exception
      when no_data_found then
        new_job;
    end;
  elsif upper(p_operation) = 'DEFAULT' then
    for i in (  select t.table_name, p.partition_name, p.high_value
                from all_part_tables t,
                     all_tab_partitions p
                where t.owner = g_aud_schema
                and   t.partitioning_type = 'RANGE'
                and   t.interval is not null
                and   t.owner = p.table_owner
                and   t.table_name = p.table_name
                and   p.partition_name like 'SYS\_P%' escape '\'
                and   t.table_name not like 'SYS\_P%' escape '\'
           ) loop
      l_stamp_clause := i.high_value;

      execute immediate
        'select to_char('||l_stamp_clause||',''YYYYMM'') from dual' into l_new_parname;

      l_new_parname := table_par_name(i.table_name)||'_p'||l_new_parname;

      logger('Renaming partition '||i.table_name||'.'||i.partition_name);
      do_sql('alter table '||g_aud_schema||'.'||i.table_name||' rename partition '||i.partition_name||' to '||l_new_parname,upper(p_action)='EXECUTE');

    end loop;
  else
    die('Invalid operation for partition tidy up');
  end if;

END;

PROCEDURE rename_column(p_owner varchar2
                       ,p_table_name varchar2
                       ,p_old_columns varchar2
                       ,p_new_columns varchar2
                       ,p_action varchar2) IS
  type col_list is table of varchar2(128);
  l_audit_table_name varchar2(60) := audit_table_name(p_table_name,p_owner);
  x number;

  l_old_cols col_list;
  l_new_cols col_list;

  procedure check_cols(p_owner varchar2,p_table_name varchar2,p_cols varchar2, p_col_list out col_list) is
    cols col_list;

    l_cols varchar2(4000) := upper(rtrim(p_cols,','))||',';
    l_col_name    varchar2(128);
    l_col_valid   boolean;

  begin
    p_col_list := col_list();
    select column_name
    bulk collect into cols
    from   all_tab_cols
    where  owner = upper(p_owner)
    and    table_name = upper(p_table_name);

    while instr(l_cols,',') > 1 loop
      l_col_name := substr(l_cols,1,instr( l_cols,',')-1);
      if l_col_name like 'AUD$%' then
        die('Renaming audit header columns is not allowed');
      end if;
      l_cols := substr(l_cols,instr( l_cols,',')+1);
      p_col_list.extend;
      p_col_list(p_col_list.count) := l_col_name;
      l_col_valid := false;
      for i in 1 .. cols.count loop
         l_col_valid := l_col_valid or cols(i) = l_col_name;
      end loop;
      if not l_col_valid then
         die(l_col_name||' is not a valid column in '||p_owner||'.'||p_table_name);
      end if;
    end loop;
  end;

BEGIN

  logger('Call to rename columns for '||p_owner||'.'||p_table_name);

  if not valid_schema(p_owner) then
    die('You can only manage audit facilities for schemas listed in '||upper('&prefix.')||'SCHEMA_LIST');
  end if;
  
  --
  -- first check for table
  --
  begin
      select 1
      into   x
      from   all_tables
      where  owner = g_aud_schema
      and    table_name = l_audit_table_name;
  exception
    when no_data_found then
      die('Audit table not found');
  end;

  --
  -- first check for table
  --
  begin
      select 1
      into   x
      from   all_tables
      where  owner = upper(p_owner)
      and    table_name = upper(p_table_name);
  exception
    when no_data_found then
      die('Audit table not found');
  end;

  check_cols(g_aud_schema,l_audit_table_name,p_old_columns,l_old_cols);
  check_cols(upper(p_owner),upper(p_table_name),p_new_columns,l_new_cols);

  if l_old_cols.count != l_new_cols.count then
     die('Column counts in old and new column lists do not match');
  end if;

  for i in 1 .. l_old_cols.count loop
      if l_old_cols(i) = l_new_cols(i) then
         die('Cannot rename column '||l_old_cols(i)||' to itself');
      end if;
      do_sql('alter table '||g_aud_schema||'.'||l_audit_table_name||' rename column '||l_old_cols(i)||' to '||l_new_cols(i),upper(p_action)='EXECUTE');
  end loop;

  generate_audit_package(p_owner,p_table_name,p_action);
  generate_audit_trigger(p_owner,p_table_name,p_action);

END;

PROCEDURE post_install(p_action varchar2) IS
  l_rows boolean := false;
BEGIN

  logger('Call to POST_INSTALL');

  for i in (  select owner, table_name, listagg(column_name,',') within group ( order by column_name ) as tag
              from (
              select c.owner, c.table_name,
                                     c.column_name,
                                     c.data_type,
                                     c.data_precision,
                                     c.data_scale,
                                     c.data_type_owner,
                                     c.data_length,
                                     c.column_id,
                                     a.data_type  aud_data_type,
                                     a.data_precision aud_data_precision,
                                     a.data_scale aud_data_scale,
                                     a.data_type_owner aud_data_type_owner,
                                     a.data_length aud_data_length
                              from   ( 
                                       select dtc.*, 
                                              case when count(distinct owner) over ( partition by table_name) > 1 then dtc.table_name||'_'||dtc.owner
                                                   else dtc.table_name
                                              end aud_table_name
                                       from   all_tab_columns dtc
                                       where  owner in ( select schema_name from &prefix.schema_list )
                                       and (  table_name in ( select table_name from all_tables where owner = g_aud_schema  )
                                          or
                                            table_name||'_'||owner in ( select table_name from all_tables where owner = g_aud_schema )
                                           )
                                       order by 1,2                                     
                                        ) c,
                                     ( select dtc.* 
                                       from all_tab_columns dtc
                                       where  owner = g_aud_schema
                                      ) a
                              where  c.column_name = a.column_name(+)
                              and    c.aud_table_name = a.table_name(+)
                              order by c.owner, c.table_name, c.column_id
              )
              where aud_data_type is null
              or ( data_type like 'TIMESTAMP%' and data_scale != aud_data_scale )
              or ( data_type like 'VARCHAR%' and data_length != aud_data_length )
              or ( data_type in ('NUMBER','BINARY_DOUBLE','BINARY_FLOAT','FLOAT') and nvl(data_precision,-1)  != nvl(aud_data_precision,-1) )
              or ( data_type in ('NUMBER','BINARY_DOUBLE','BINARY_FLOAT','FLOAT') and nvl(data_scale,-1)  != nvl(aud_data_scale,-1) )
              or ( data_type like 'INTERVAL%' and nvl(data_precision,-1)  != nvl(aud_data_precision,-1) )
              or ( data_type like 'INTERVAL%' and nvl(data_scale,-1)  != nvl(data_scale,-1) )
              or ( data_type in ('RAW','CHAR','VARCHAR2','NCHAR','NVARCHAR2') and data_length != aud_data_length )
              group by owner, table_name
  )
  loop
    if upper(p_action) = 'REPORT' then
      if not l_rows then
        dbms_output.put_line(rpad('Owner',32)||'Table');
        dbms_output.put_line(rpad('---------------',32)||'------------------');
        l_rows := true;      
      end if;    
      dbms_output.put_line(rpad(i.owner,32)||rpad(i.table_name,32)||i.tag);
    else
      l_rows := true;      
      begin
          generate_audit_support(i.owner,i.table_name,p_action=>p_action);
      exception
        when others then
          logger('Failed with '||sqlerrm);
      end;
    end if;
  end loop;

  if not l_rows then
     dbms_output.put_line('No work to do on existing audited tables');
  end if;    

END;

END; -- package body
/
sho err
