package Mojolicious::Plugin::Fondation::MigrationDBIx::Command::db;

# ABSTRACT: Database migration and fixture commands for DBIx::Class backends

use Mojo::Base 'Mojolicious::Command', -signatures;

use Mojo::File 'path';
use JSON::MaybeXS;

our $VERSION = '0.02';

has description => 'Manage database migrations and fixtures for DBIx backends';
has usage       => sub ($self) {
    <<"USAGE";
Usage: APPLICATION db COMMAND [OPTIONS]

  myapp.pl db prepare [-y]          Copy DBIx migrations + fixtures from plugins
  myapp.pl db install               Run pending DBIx migrations
  myapp.pl db upgrade               Upgrade one version
  myapp.pl db downgrade             Downgrade one version
  myapp.pl db status                Show current migration version
  myapp.pl db populate [--set SET]  Load DBIx fixture data (default: '1')

USAGE
};

sub run ($self, @args) {
    my $app = $self->app;
    my $subcommand = shift @args || '';

    my $config = $app->defaults->{'migration_dbix.config'}
        or die "MigrationDBIx not configured. Add Fondation::MigrationDBIx to your config.\n";

    for ($subcommand) {
        /^install$/   and return $self->_install($app, $config, @args);
        /^upgrade$/   and return $self->_upgrade($app, $config, @args);
        /^downgrade$/ and return $self->_downgrade($app, $config, @args);
        /^status$/    and return $self->_status($app, $config, @args);
        /^prepare$/   and return $self->_prepare($app, $config, @args);
        /^populate$/  and return $self->_populate($app, $config, @args);
        die $self->usage;
    }
}

# ---------------------------------------------------------------------------
# Build a DeploymentHandler with ignore_ddl => 1
# ---------------------------------------------------------------------------

sub _build_dh ($self, $app, $config) {
    my $native = $self->_build_native_schema($app, $config)
        or return undef;

    my $mig_dir = path($config->{migrations_dir});

    # Derive database type from DSN (e.g. dbi:SQLite:... → SQLite, dbi:Pg:... → Pg)
    my $c    = $app->build_controller;
    my $bdef = $c->backend_config($config->{backend});
    my ($driver) = $bdef->{dsn} =~ /^dbi:([^:]+):/i
        or die "Cannot parse DSN: $bdef->{dsn}\n";

    require DBIx::Class::DeploymentHandler;
    return DBIx::Class::DeploymentHandler->new(
        schema              => $native,
        script_directory    => $mig_dir->to_string,
        databases           => [$driver],
        sql_translator_args => { add_drop_table => 0 },
        ignore_ddl          => 1,
    );
}

# ---------------------------------------------------------------------------
# db prepare — generate SQL from schema + copy fixtures from plugins
# ---------------------------------------------------------------------------

sub _prepare ($self, $app, $config, @args) {
    my $yes = grep { $_ eq '-y' } @args;

    my $mig_dir = path($config->{migrations_dir});
    my $fix_dir = $app->home->child('share', 'fixtures');

    # Check if target directories already have content
    my @existing;
    push @existing, 'migrations' if $self->_dir_has_content($mig_dir);
    push @existing, 'fixtures'   if $self->_dir_has_content($fix_dir);

    if (@existing && !$yes) {
        my $counts = '';
        $counts .= sprintf "  %-12s %d file(s)\n", 'migrations',
            $self->_file_count($mig_dir) if $self->_dir_has_content($mig_dir);
        $counts .= sprintf "  %-12s %d file(s)\n", 'fixtures',
            $self->_file_count($fix_dir) if $self->_dir_has_content($fix_dir);
        say "\nTarget directories already have content:";
        print $counts;
        say "";
        print "Overwrite existing files? [y/N] ";
        my $answer = <STDIN>;
        chomp $answer;
        exit(0) unless $answer =~ /^y(es)?$/i;
    }

    my $force = $yes || (@existing > 0);

    # Generate SQL from schema classes via DeploymentHandler
    my $dh = $self->_build_dh($app, $config);
    if ($dh) {
        # Remove existing generated dirs so DeploymentHandler regenerates cleanly
        $mig_dir->child('_source')->remove_tree if $force && -d $mig_dir->child('_source');
        $mig_dir->child('SQLite')->remove_tree  if $force && -d $mig_dir->child('SQLite');

        $dh->prepare_install;
        say "Done.";
    }

    # Copy fixture tree from all plugins
    my $fix_copied = $self->_copy_tree_from_plugins(
        $app, 'fixtures', $fix_dir, $force);
    say sprintf "Fixtures:   %d file(s) copied.",   $fix_copied   if $fix_copied;
}

# ---------------------------------------------------------------------------
# Copy a share subdirectory tree from all plugins to the app
# ---------------------------------------------------------------------------

sub _copy_tree_from_plugins ($self, $app, $subdir, $target_dir, $force) {
    my $manager = $app->manager;
    my $copied  = 0;

    # Clean target if forcing overwrite
    $target_dir->remove_tree({ keep_root => 1 }) if $force && -d $target_dir;
    $target_dir->make_path unless -d $target_dir;

    for my $long (sort keys %{$manager->registry}) {
        my $entry = $manager->registry->{$long};
        my $share = $entry->{share_dir} or next;
        my $src_root = $share->child($subdir);
        next unless -d $src_root;

        my @all_files = @{ $src_root->list_tree({ hidden => 1 }) // [] };
        for my $src (@all_files) {
            next unless -f $src;

            my $rel_path = $src->to_rel($share);
            my $target   = $app->home->child('share', $rel_path);

            next if -e $target && !$force;

            $target->dirname->make_path unless -d $target->dirname;
            eval { $src->copy_to($target); 1 }
                or do {
                    warn "  Failed to copy $rel_path: $@\n";
                    next;
                };
            $copied++;
        }
    }

    return $copied;
}

# ---------------------------------------------------------------------------
# db install — run DeploymentHandler install
# ---------------------------------------------------------------------------

sub _install ($self, $app, $config, @args) {
    my $dh = $self->_build_dh($app, $config)
        or return;

    my $mig_dir = path($config->{migrations_dir});

    unless (-d $mig_dir) {
        say "No migrations directory: $mig_dir";
        say "Run 'db prepare' first to generate migration files from schema.";
        return;
    }

    my $schema_v = $dh->schema_version;
    my $db_v     = $dh->version_storage_is_installed
        ? $dh->database_version : 0;

    if ($db_v && $db_v >= $schema_v) {
        say "Already at version $db_v (schema: $schema_v). Nothing to migrate.";
        return;
    }

    say "Installing schema (version $schema_v)...";
    $dh->install;
    my $active = eval { $dh->database_version } // $schema_v;
    say "Done. Active version: $active";
}

# ---------------------------------------------------------------------------
# db upgrade — run pending upgrades
# ---------------------------------------------------------------------------

sub _upgrade ($self, $app, $config, @args) {
    my $dh = $self->_build_dh($app, $config)
        or return;

    my $db_v     = $dh->version_storage_is_installed
        ? $dh->database_version : 0;
    my $schema_v = $dh->schema_version;

    return say "Already at latest version $db_v." if $db_v >= $schema_v;

    say "Upgrading from version $db_v to " . ($db_v + 1) . "...";
    $dh->upgrade;
    say "Done. Active version: " . $dh->database_version;
}

# ---------------------------------------------------------------------------
# db downgrade — rollback one version
# ---------------------------------------------------------------------------

sub _downgrade ($self, $app, $config, @args) {
    my $dh = $self->_build_dh($app, $config)
        or return;

    my $db_v = $dh->version_storage_is_installed
        ? $dh->database_version : 0;
    die "No version installed. Nothing to downgrade.\n" unless $db_v;

    say "Downgrading from version $db_v to " . ($db_v - 1) . "...";
    $dh->downgrade;
    say "Done. Active version: " . $dh->database_version;
}

# ---------------------------------------------------------------------------
# db status — show current vs latest migration version
# ---------------------------------------------------------------------------

sub _status ($self, $app, $config, @args) {
    my $dh = $self->_build_dh($app, $config)
        or return;

    my $schema_v = $dh->schema_version // 'unknown';
    my $db_v     = $dh->version_storage_is_installed
        ? $dh->database_version : 'none';

    say "Schema version : $schema_v";
    say "Active version : $db_v";
    say "Status         : "
        . ($dh->version_storage_is_installed && $db_v >= $schema_v
            ? "up to date" : "migrations pending");
}

# ---------------------------------------------------------------------------
# db populate — load DBIx fixtures
# ---------------------------------------------------------------------------

sub _populate ($self, $app, $config, @args) {
    my $set_version = '1';
    my $set_filter;  # undef = all sets

    # Parse --set option
    for (my $i = 0; $i < @args; $i++) {
        if ($args[$i] eq '--set' && defined $args[$i + 1]) {
            $set_filter = $args[$i + 1];
            last;
        }
    }

    my $native = $self->_build_native_schema($app, $config)
        or return;

    my $mig_dir    = path($config->{migrations_dir});
    my $target_dir = $mig_dir->dirname->to_string;

    require DBIx::Class::Migration;
    my $migration = DBIx::Class::Migration->new(
        schema     => $native,
        target_dir => $target_dir,
    );

    my $conf_dir = $app->home->child('share', 'fixtures', $set_version, 'conf');

    unless (-d $conf_dir) {
        die "Fixture config directory not found: $conf_dir\n";
    }

    # Discover available set names from conf/*.json
    my @all_sets;
    for my $file (sort $conf_dir->list({ file => 1 })->each) {
        next unless $file->basename =~ /\.json$/i;
        (my $set_name = $file->basename) =~ s/\.json$//i;
        push @all_sets, $set_name;
    }

    unless (@all_sets) {
        say "No fixture sets found in $conf_dir";
        return;
    }

    # Filter by --set or use all
    my @sets = $set_filter
        ? grep { $_ eq $set_filter } @all_sets
        : @all_sets;

    unless (@sets) {
        die "Fixture set '$set_filter' not found. Available: "
            . join(', ', @all_sets) . "\n";
    }

    say "Populating set(s): " . join(', ', @sets);
    $migration->populate(@sets);
    say "Populate complete.";
}

# ---------------------------------------------------------------------------
# Build a native DBIx::Class::Schema from backend config
# ---------------------------------------------------------------------------

sub _build_native_schema ($self, $app, $config) {
    # Resolve backend: explicit config → DBIx::Async default → first backend → undef
    my $c = $app->build_controller;
    my $backend_name;
    if ($c->has_helper('default_backend_name')) {
        $backend_name = $c->default_backend_name($config->{backend});
    } else {
        $backend_name = $config->{backend};
    }

    unless ($backend_name) {
        say "No backend configured. Set 'backend' in MigrationDBIx config"
            . " or 'default_backend' in Fondation::Model::DBIx::Async.";
        return undef;
    }

    my $bdef;
    unless ($app->has_helper('backend_config')) {
        say "Fondation::Model::DBIx::Async is not loaded. No backend_config helper.";
        return undef;
    }

    $bdef = eval { $c->backend_config($backend_name) };
    unless ($bdef) {
        say "Backend '$backend_name' not found.";
        return undef;
    }

    my $schema_class = $bdef->{schema_class}
        or die "No schema_class configured for backend '$backend_name'\n";

    eval "require $schema_class; 1"
        or die "Cannot load schema class $schema_class: $@\n";

    # Ensure parent directory exists for file-based DSNs (SQLite)
    if ($bdef->{dsn} =~ /^dbi:SQLite:(?:dbname=)?(.+)$/i) {
        my $db_path = $1;
        my $dir = Mojo::File->new($db_path)->dirname;
        $dir->make_path unless -d $dir;
    }

    my $native = $schema_class->connect(
        $bdef->{dsn},
        $bdef->{user}      // '',
        $bdef->{pass}      // '',
        $bdef->{dbi_attrs} // {},
    );

    return $native;
}

# ---------------------------------------------------------------------------
# Helpers for directory content detection
# ---------------------------------------------------------------------------

sub _dir_has_content ($self, $dir) {
    return 0 unless -d $dir;
    my @files = grep { -f $_ } @{ $dir->list_tree({ hidden => 1 }) // [] };
    return scalar @files > 0;
}

sub _file_count ($self, $dir) {
    return 0 unless -d $dir;
    return scalar grep { -f $_ } @{ $dir->list_tree({ hidden => 1 }) // [] };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Mojolicious::Plugin::Fondation::MigrationDBIx::Command::db - Database migration and fixture commands

=head1 SYNOPSIS

  $ myapp.pl db prepare
  $ myapp.pl db install
  $ myapp.pl db status
  $ myapp.pl db populate --set 1

=head1 DESCRIPTION

Command-line interface for managing database migrations and fixtures
for DBIx::Class backends managed by L<Fondation::Model::DBIx::Async>.

Migrations use L<DBIx::Class::DeploymentHandler> directly with C<ignore_ddl = 1>.
Upgrade and downgrade SQL are generated on-the-fly from C<_source/> YAML files —
no C<db dump> step is needed.

=cut
