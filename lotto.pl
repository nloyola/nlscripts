#!/usr/bin/perl -w

use strict;
use LWP::Simple;
use Date::Manip;
use Data::Dumper;

# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab
# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab&date=2007-05-02

my %numbers;
my @past_dates = ();

my $num_table = 0;
my $date_options = 0;

my $lottoUrl = 'http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab';

my %our_numbers = ('A' => [2, 7, 11, 25, 29, 48],
                   'B' => [9, 33, 35, 36, 37, 46]);


my @valid_dates = ('2007-02-03', '2008-01-30');

sub parseLottoNumbers {
    my $url = shift;
    my $get_past_draws = shift;
    my $doc = get $url;
    my @numbers = ();

    for my $line (split("\n", $doc)) {
        if ($line =~ /header.*winning numbers/) {
            $num_table = 1;
        }
        elsif ($line =~ /See results from past dates/)
        {
            $num_table = 0;
            if ($get_past_draws) {
                $date_options = 1;
            }
        }
        elsif ($get_past_draws && ($line =~ /<\/form>/))
        {
            $date_options = 0;
        }
        elsif ($line eq "") {
            next;
        }

        if ($num_table) {
            if ($line =~ /<td><font class="faceonly" size="2">(\d{1,2})<\/font><\/td>/) {
                push (@numbers, $1);
            }

            if ($line =~ /<td bgcolor="#eeeeee" align="center"><font class="faceonly" size="2">(\d{1,2})<\/font><\/td>/) {
                push (@numbers, 'b' . $1);
            }
        }

        if ($get_past_draws && $date_options) {
            if ($line =~ /<option value="(\d{4})-(\d{2})-(\d{2})">/) {
                push (@past_dates, $1 . '-' . $2 . '-' . $3);
            }
        }
    }

    return @numbers;
}

# the first call is to get the draw dates
parseLottoNumbers($lottoUrl, 1);

foreach my $date (@past_dates) {
    if (Date_Cmp($date, $valid_dates[0]) < 0) {
        last;
    }

    my $url = $lottoUrl . '&date=' . $date;
    print "Fetching numbers for " . $date . "...\n";
    @{ $numbers{$date} } = parseLottoNumbers($url, 0);
}

print "\n\nOur numbers:\n";
foreach my $ours (keys %our_numbers) {
    print "  " . $ours . ") " . join(', ', @{ $our_numbers{$ours} }) . "\n";
}

print "\n\t\t\t\t\tNum Matches\n"
    . "Draw\t\tNumbers\t\t\tA\tB\tWinnings\n"
    . "--------------- ----------------------- ------- ------- ---------------\n";

foreach my $date (sort keys %numbers) {
    my %matches = ();
    my %bonus_matches = ();

    foreach my $ours (keys %our_numbers) {
        $matches{$ours} = 0;
        $bonus_matches{$ours} = 0;
    }

    if (scalar @{ $numbers{$date} } == 7) {
        print $date . "\t";

        print join(' ', @{ $numbers{$date} }) . "\t";

        foreach my $num (@{ $numbers{$date} }) {
            foreach my $ours (keys %our_numbers) {

                foreach my $mynum (@{ $our_numbers{$ours} }) {
                    if ($num =~ /b(\d+)/) {
                        if ($mynum == $1) {
                            ++$bonus_matches{$ours};
                        }
                    }
                    elsif ($mynum == $num) {
                        ++$matches{$ours};
                    }
                }
            }
        }

        foreach my $ours (keys %matches) {
            if ($bonus_matches{$ours} == 0) {
                print $matches{$ours} . "\t";
            }
            else {
                print $matches{$ours} . " (" . $bonus_matches{$ours} . ")\t";
            }
        }
    }

    foreach my $ours (keys %matches) {
        if (($matches{$ours} == 2) && ($bonus_matches{$ours} == 1)) {
            print "won \$5 with ". $ours;
        }
        elsif ($matches{$ours} == 3) {
            print "won \$10 with ". $ours;
        }
        elsif ($matches{$ours} == 4) {
            print "won \$80.10 with ". $ours;
        }
        elsif ($matches{$ours} == 5) {
            print "won \$2,361.90 with ". $ours;
        }
        elsif (($matches{$ours} == 5) && ($bonus_matches{$ours} == 1)) {
            print "won \$105,790.90 with ". $ours;
        }
        elsif ($matches{$ours} == 6) {
            print "won GRAND PRIZE with ". $ours;
        }
    }

    print "\n";
}
