
# Test Astro::Telescope

use strict;
use Test;

BEGIN { plan tests => 16 }

use Astro::Telescope;

my $tel = new Astro::Telescope( 'JCMT' );

ok( $tel );

ok( $tel->name, "JCMT");
ok( $tel->fullname, "JCMT 15 metre");
ok( $tel->long("s"),"-155 28 37.20" );
ok( $tel->lat( "s"), "19 49 22.11");
ok( $tel->alt(), 4111);

# Check limits
my %limits = $tel->limits;

ok( $limits{type}, "AZEL");
ok(exists $limits{el}{max} );
ok(exists $limits{el}{min} );

# Switch telescope
$tel->name( "UKIRT" );
ok( $tel->name, "UKIRT");
ok( $tel->fullname, "UK Infra Red Telescope");

%limits = $tel->limits;
ok( $limits{type}, "HADEC");
ok(exists $limits{ha}{max} );
ok(exists $limits{ha}{min} );
ok(exists $limits{dec}{max} );
ok(exists $limits{dec}{min} );
