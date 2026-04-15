#use Image::Resize;
use GD;
use GD::Simple;
use GD::Barcode::EAN13;
use Business::Barcode::EAN13 qw/valid_barcode check_digit issuer_ccode best_barcode/;
use GD::Barcode::QRcode;

# Use as follows
# rm eancodes.txt ; cat codes.txt | while read line; do perl ./barcodes.pl $line; done
# Where codes.txt contains lines such as 000000000000 /this-url/
# the first parameter is the 12 digit EAN13 code and the second parameter is the URL for the product
# When these two parameters are passed the script generates two files
# Each .png file has text at the top that contains a cleaned up version of the URL
# The bottom of each file is either a EAN13 barcode or a QRCode pointing to the product URL
# These should be used on separate sides of the product packaging so they are scanned independenty



# binmode(STDOUT);

my $eancode = $ARGV[0] . check_digit($ARGV[0]);


my $url = "https://danks.store" . $ARGV[1];
my $name = $ARGV[1];
$name =~ s/\///g;
$name =~ s/\-/\ /g;

print $eancode . "\n";
print $url . "\n"; 
print $name . "\n";

$image = GD::Image->new(300,30);
$barcode = GD::Barcode::EAN13->new($eancode)->plot(Height => 100);
$qrcode = GD::Barcode::QRcode->new($url, {ECC => 'M', Version => 12, ModuleSize => 4})->plot;

 
$white = $image->colorAllocate(255,255,255);
$black = $image->colorAllocate(0,0,0);
#$image->transparent($white);
#$image->interlaced('true');
$image->string(gdLargeFont, 14, 10, $name, $black); 


#my $resizer = Image::Resize->new($barcode);
#$barcode = $resizer->resize(300, 100);

#$resizer = Image::Resize->new($qrcode);
#$qrcode = $resizer->resize(300, 100);

my( $x1, $y1 ) = $image->getBounds();
my( $x2, $y2 ) = $barcode->getBounds();

my( $x3, $y3 ) = ( $x1 > $x2 ? $x1 : $x2, $y1 + $y2 );

my $barimage = GD::Image->new( $x3, $y3, 1 );
$barimage->copy( $image, 0, 0, 0, 0, $x1, $y1 );
#$barimage->copy( $barcode, 0, $y1, 0, 0, $x2, $y2 );
$barimage->copyResized( $barcode, 0, $y1, 0, 0, $x1, $y2, $x2, $y2 );

( $x1, $y1 ) = $image->getBounds();
( $x2, $y2 ) = $qrcode->getBounds();

( $x3, $y3 ) = ( $x1 > $x2 ? $x1 : $x2, $y1 + $y2 );

my $qrimage = GD::Image->new( $x3, $y3, 1 );
$qrimage->copy( $image, 0, 0, 0, 0, $x1, $y1 );
$qrimage->copyResized( $qrcode, 0, $y1, 0, 0, $x1, $y2, $x2, $y2 );

open my $eancodes, ">>", "eancodes.txt" or die;
print $eancodes $eancode . "\n";
close $eancodes;

open my $out, ">", $name . "barcode.png" or die;
open my $out1, ">", $name . "qrcode.png" or die;

binmode $out;
binmode $out1;
#print $out $image->png;
#print $out $qrcode->png;
#print $out $barcode->png;

print $out $barimage->png;
print $out1 $qrimage->png;

close $out;
close $out1;

# print "Content-Type: image/png\n\n";
# print GD::Barcode::EAN13->new('123456789012')->plot->png;



