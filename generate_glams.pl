#!/usr/bin/perl
use warnings;
use strict;
use DBI;
use JSON;

# Constants
my $primary           = 8192;
my $secondary         = 16384;
my $range             = 2048;
my $glam_template     = 2828;
my $glam_start_range  = 700000;
my $max_name_length   = 64;

sub LoadMysql {
    my $json = JSON->new();
    open(my $fh, '<', "../eqemu_config.json") or die "Cannot open config file: $!";
    local $/;
    my $content = <$fh>;
    close($fh);
    my $config = $json->decode($content);
    my $dsn = "dbi:mysql:$config->{server}{content_database}{db}:$config->{server}{content_database}{host}:3306";
    return DBI->connect($dsn, $config->{server}{content_database}{username}, $config->{server}{content_database}{password}, { RaiseError => 1, PrintError => 0, AutoCommit => 0 });
}

my $dbh = LoadMysql();

# Get columns
my $col_stmt = $dbh->prepare("SHOW COLUMNS FROM items");
$col_stmt->execute();
my @columns;
push @columns, $_->{Field} while $_ = $col_stmt->fetchrow_hashref();
$col_stmt->finish();

# Get glamour template
my $template_stmt = $dbh->prepare("SELECT * FROM items WHERE id = ?");
$template_stmt->execute($glam_template);
my $template_item = $template_stmt->fetchrow_hashref();
$template_stmt->finish();
die "Template item with ID $glam_template not found.\n" unless $template_item;

# Remove modifiable columns
my @mod_columns = grep { $_ ne 'id' && $_ ne 'Name' && $_ ne 'slots' } @columns;

# Get existing glamour names to prevent duplicates
my %existing_names;
my %used_ids;
my $existing_g_stmt = $dbh->prepare("SELECT id, Name FROM items WHERE id >= ?");
$existing_g_stmt->execute($glam_start_range);
while (my $row = $existing_g_stmt->fetchrow_hashref) {
    $existing_names{$row->{Name}} = 1;
    $used_ids{$row->{id}} = 1;
}
$existing_g_stmt->finish();

# Helper to find the next available ID in the glamour range
my $next_glam_id = $glam_start_range;
sub get_next_glam_id {
    while ($used_ids{$next_glam_id}) {
        $next_glam_id++;
    }
    $used_ids{$next_glam_id} = 1;
    return $next_glam_id++;
}

# Prepare insert statement
my $insert_sql = "INSERT IGNORE INTO items (" . join(", ", map { "`$_`" } @columns) . ") VALUES (" . join(", ", map { "?" } @columns) . ")";
my $insert_stmt = $dbh->prepare($insert_sql);

# Select base items
my $select_stmt = $dbh->prepare(<<'SQL');
    SELECT * FROM items
    WHERE items.id < 999999 
    AND items.classes <> 0 
    AND items.races <> 0 
    AND (items.slots & ?) <> 0
    AND NOT items.itemtype = 54
SQL
$select_stmt->execute($primary | $secondary | $range);

# Dry-run collection
my @insert_queue;

while (my $original = $select_stmt->fetchrow_hashref) {
    # Generate glamour name
    my $prefix = "Glamour - '";
    my $suffix = "'";
    my $base = $original->{Name};
    my $avail_len = $max_name_length - length($prefix) - length($suffix);
    my $truncated = length($base) > $avail_len ? substr($base, 0, $avail_len - 3) . "..." : $base;
    my $new_name = "$prefix$truncated$suffix";

    # Skip if name already exists
    if ($existing_names{$new_name}) {
        print "Skipping (name exists): $new_name\n";
        next;
    }
    $existing_names{$new_name} = 1;

    # Assign next available ID in glamour range
    my $new_id = get_next_glam_id();

    # Adjust slots
    my $new_slots = $original->{slots} & ($primary | $secondary | $range);

    # Build values
    my @values = map {
        $_ eq 'id'     ? $new_id
      : $_ eq 'Name'   ? $new_name
      : $_ eq 'slots'  ? $new_slots
      : $_ eq 'idfile' ? $original->{idfile}
      : $_ eq 'icon'   ? $original->{icon}
      :                $template_item->{$_}
    } @columns;

    push @insert_queue, \@values;
    print "Will insert: $new_name (ID $new_id)\n";
}

$select_stmt->finish();

# Prompt user for confirmation
my $count = scalar @insert_queue;
if ($count == 0) {
    print "\nNo new glamour items to insert.\n";
    $dbh->disconnect();
    exit;
}

print "\n$count glamour items are queued for insertion.\n";
print "Proceed with database changes? (yes/no): ";
my $answer = <STDIN>;
chomp($answer);

if (lc($answer) eq 'yes' || lc($answer) eq 'y') {
    foreach my $values (@insert_queue) {
        $insert_stmt->execute(@$values);
    }
    $dbh->commit();
    print "\nCommitted $count glamour items.\n";
} else {
    $dbh->rollback();
    print "\nAborted. No changes committed.\n";
}

$insert_stmt->finish();
$dbh->disconnect();
