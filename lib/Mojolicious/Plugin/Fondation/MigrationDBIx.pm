package Mojolicious::Plugin::Fondation::MigrationDBIx;

# ABSTRACT: Migration and fixture management for DBIx::Class backends

use Mojo::Base 'Mojolicious::Plugin', -signatures;

our $VERSION = '0.01';

sub fondation_meta {
    return {
        dependencies => ['Fondation::Model::DBIx::Async'],
        defaults     => {
            title => 'DBIx Database Migration',
        },
    };
}

sub register ($self, $app, $config) {

    my $backend_name = $config->{backend};

    my $migrations_dir = $config->{migrations_dir}
        // $app->home->child('share', 'migrations')->to_string;

    $app->defaults('migration_dbix.config' => {
        backend        => $backend_name,
        migrations_dir => $migrations_dir,
    });

    push @{$app->commands->namespaces},
        'Mojolicious::Plugin::Fondation::MigrationDBIx::Command';

    return $self;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Mojolicious::Plugin::Fondation::MigrationDBIx - Migration and fixture
management for DBIx::Class backends

=head1 VERSION

0.01

=head1 SYNOPSIS

  # myapp.conf
  {
      'Fondation' => {
          dependencies => [
              { 'Fondation::Model::DBIx::Async' => {
                  backends => { main => { ... } },
              }},
              { 'Fondation::MigrationDBIx' => {
                  backend => 'main',    # optional — uses DBIx::Async default
              }},
          ],
      },
  }

  # Commands
  $ myapp.pl db bootstrap-schema      # Create a minimal Schema class
  $ myapp.pl db prepare               # Generate SQL + copy fixtures from plugins
  $ myapp.pl db install               # Run pending migrations
  $ myapp.pl db upgrade               # Upgrade one version
  $ myapp.pl db downgrade             # Downgrade one version
  $ myapp.pl db status                # Show current migration version
  $ myapp.pl db populate [--set 1]    # Load fixture data

=head1 DESCRIPTION

L<Mojolicious::Plugin::Fondation::MigrationDBIx> provides C<db> commands for
managing database migrations and fixtures for DBIx::Class backends managed by
L<Fondation::Model::DBIx::Async>.

=head2 Migration workflow

The typical workflow:

  myapp.pl db bootstrap-schema  # Step 0 (optional): create Schema class if none
  myapp.pl db prepare           # Step 1: generate SQL from schema classes
  myapp.pl db install           # Step 2: apply migrations to the database
  myapp.pl db populate          # Step 3: load initial data

For incremental changes, edit your schema, re-run C<db prepare>, then
C<db upgrade> / C<db downgrade>.

=head2 How it works

=over

=item *

B<DBIx::Class::DeploymentHandler> with C<ignore_ddl = 1>.
Upgrade and downgrade SQL are generated on-the-fly from C<_source/> YAML files
— no C<db dump> step needed.

=item *

B<Backend resolution>: explicit C<backend> config → C<default_backend> from
DBIx::Async → first backend configured. Dies if no backend can be resolved.

=item *

B<Driver detection>: the database driver (SQLite, Pg, mysql) is parsed from
the DSN, never hardcoded.

=item *

B<Plugin fixtures>: C<db prepare> scans all loaded plugins for
C<share/fixtures/> directories and copies them to the app's C<share/fixtures/>.

=item *

B<db populate> uses L<DBIx::Class::Migration> to load fixture data from
C<share/fixtures/VERSION/conf/*.json>.

=back

=head2 Plugin fixture discovery

Any Fondation plugin can ship fixtures in C<share/fixtures/>. During
C<db prepare>, they are copied to the application's C<share/fixtures/>
directory. The directory structure is:

  share/fixtures/
  └── 1/                     # schema version
      ├── conf/
      │   └── my_set.json    # fixture set configuration
      └── my_set/
          └── my_table/
              └── 1.fix      # fixture data

=head1 CONFIGURATION

  'Fondation::MigrationDBIx' => {
      backend        => 'main',    # optional — defaults to DBIx::Async default
      migrations_dir => '/path',   # optional — defaults to <app>/share/migrations
  }

=head3 backend

Name of the DBIx::Async backend to target. When omitted, falls back to
C<default_backend> in DBIx::Async config, then to the first backend.

=head3 migrations_dir

Custom path for migration files. Defaults to C<E<lt>app homeE<gt>/share/migrations>.

=head1 COMMANDS

All commands are invoked as C<myapp.pl db COMMAND [OPTIONS]>.

=head2 db bootstrap-schema [--class ClassName] [--backend name] [--force]

Creates a minimal L<DBIx::Class::Schema> class file under C<lib/>. Use this
when you have DBIx backends configured but no C<schema_class> yet. After
creating the file, add C<schema_class> to your backend config and run
C<db prepare> to generate migration files.

The generated class uses C<load_namespaces> to auto-discover any C<Result>
classes under the application's C<Schema::Result::*> namespace. Result
classes from Fondation plugins are registered separately by the C<DBIx>
action before workers fork — both mechanisms coexist transparently.

When both the application and a plugin define a C<Result> class for the
same table, the application's class wins: C<load_namespaces> runs during
C<connect()>, I<after> the C<DBIx> action has registered plugin sources.
This lets you extend or replace a plugin's Result class by defining your
own with the same C<< __PACKAGE__->table(...) >>.

=head2 db prepare [-y]

Generates SQL migration files from the schema classes and copies fixture
directories from all loaded plugins into the application. Use C<-y> to
skip the overwrite prompt.

=head2 db install

Runs all pending migrations. Creates the version storage table on first run.
If already at the latest version, prints a message and exits.

=head2 db upgrade

Applies the next pending upgrade (one version at a time). Useful for testing
incremental migration steps.

=head2 db downgrade

Rolls back the last applied migration (one version at a time).

=head2 db status

Shows the current schema version (from source files) and the active database
version.

=head2 db populate [--set SET]

Loads fixture data from C<share/fixtures/VERSION/>. Use C<--set> to filter
by set name. Defaults to loading all sets under version C<1>.

=head1 SEE ALSO

=over

=item *

L<Mojolicious::Plugin::Fondation::Model::DBIx::Async> — database backend plugin

=item *

L<DBIx::Class::DeploymentHandler> — migration engine

=item *

L<DBIx::Class::Migration> — fixture loading

=back

=cut
