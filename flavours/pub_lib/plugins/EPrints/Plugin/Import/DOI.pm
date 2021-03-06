=head1 NAME

EPrints::Plugin::Import::DOI

=cut

package EPrints::Plugin::Import::DOI;

# 10.1002/asi.20373

use strict;

use EPrints::Plugin::Import::TextFile;
use URI;

our @ISA = qw/ EPrints::Plugin::Import::TextFile /;

sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    $self->{name} = "DOI (via CrossRef)";
    $self->{visible} = "all";
    $self->{produce} = [ 'dataobj/eprint', 'list/eprint' ];
    $self->{screen} = "Import::DOI";

    # http://www.crossref.org/openurl - original url, valid up to feb 2017
    # https://doi.crossref.org/openurl - current preferred url, but below code does not support https
    $self->{ base_url } = "http://doi.crossref.org/openurl";

    return $self;
}

sub screen
{
    my( $self, %params ) = @_;

    return $self->{repository}->plugin( "Screen::Import::DOI", %params );
}

sub input_text_fh
{
    my( $plugin, %opts ) = @_;

    my @ids;

    my $pid = $plugin->param( "pid" );
    my $session = $plugin->{repository};
    my $use_prefix = $plugin->param( "use_prefix" ) || 1;
    my $doi_field = $plugin->param( "doi_field" ) || 'id_number';

    unless( $pid )
    {
        $plugin->error( 'You need to configure your pid by setting the `pid\' variable in cfg.d/plugins.pl (see http://www.crossref.org/openurl): $c->{plugins}->{"Import::DOI"}->{params}->{pid} = "ourl_username:password";' );
        return undef;
    }

    my $fh = $opts{fh};
    while( my $doi = <$fh> )
    {
        $doi =~ s/^\s+//;
        $doi =~ s/\s+$//;

        next unless length($doi);
	my $obj = EPrints::DOI->parse( $doi );
	if( $obj )
	{
		$doi = $obj->to_string( noprefix => !$use_prefix );
	}

        #some doi's in the repository may have the "doi:" prefix and others may not, so we need to check both cases - rwf1v07:27/01/2016
        my $doi2 = $doi;
        $doi =~ s/^(doi:)?//i;
        $doi2 =~ s/^(doi:)?/doi:/i;

        # START check and exclude DOI from fetch if DOI already exists in the 'archive' dataset - Alan Stiles, Open University, 20140408
        my $duplicates = $session->dataset( 'archive' )->search(
                        filters =>
                        [
                            { meta_fields => [$doi_field], value => "$doi $doi2", match => "EQ", merge => "ANY" }, #check for both "doi:" prefixed values and ones which aren't prefixed - rwf1v07:27/01/2016
                        ]
        );
        if ( $duplicates->count() > 0 )
        {
            $plugin->handler->message( "warning", $plugin->html_phrase( "duplicate_doi",
                doi => $plugin->{session}->make_text( $doi ),
                msg => $duplicates->item( 0 )->render_citation_link(),
            ));
            next;
        }
        # END check and exclude DOI from fetch if DOI already exists in the 'archive' dataset - Alan Stiles, Open University, 20140408
    
        my %params = (
            pid => $pid,
            noredirect => "true",
            id => $doi,
        );

        my $url = URI->new( $plugin->{ base_url } );
        $url->query_form( %params );

        my $dom_doc;
        eval {
            $dom_doc = EPrints::XML::parse_url( $url );
        };

        my $dom_top = $dom_doc->getDocumentElement;

        my $dom_query_result = ($dom_top->getElementsByTagName( "query_result" ))[0];

        if( $@ || !defined $dom_query_result)
        {
            $plugin->handler->message( "warning", $plugin->html_phrase( "invalid_doi",
                doi => $plugin->{session}->make_text( $doi ),
                msg => $plugin->{session}->make_text( "No or unrecognised response" )
            ));
            next;
        }

        my $dom_body = ($dom_query_result->getElementsByTagName( "body" ))[0];
        my $dom_query = ($dom_body->getElementsByTagName( "query" ))[0];
        my $status = $dom_query->getAttribute( "status" );

        if( defined($status) && ($status eq "unresolved" || $status eq "malformed") )
        {
            my $msg = ($dom_query->getElementsByTagName( "msg" ))[0];
            $msg = EPrints::Utils::tree_to_utf8( $msg );
            $plugin->handler->message( "warning", $plugin->html_phrase( "invalid_doi",
                doi => $plugin->{session}->make_text( $doi ),
                msg => $plugin->{session}->make_text( $msg )
            ));
            next;
        }

        my $data = { doi => $doi };
        foreach my $node ( $dom_query->getChildNodes )
        {
            next if( !EPrints::XML::is_dom( $node, "Element" ) );
            my $name = $node->tagName;
            if( $node->hasAttribute( "type" ) )
            {
                $name .= ".".$node->getAttribute( "type" );
            }
            if( $name eq "contributors" )
            {
                $plugin->contributors( $data, $node );
            }
            else
            {
                $data->{$name} = EPrints::Utils::tree_to_utf8( $node );
            }
        }

        EPrints::XML::dispose( $dom_doc );

        my $epdata = $plugin->convert_input( $data );
        next unless( defined $epdata );

        my $dataobj = $plugin->epdata_to_dataobj( $opts{dataset}, $epdata );
        if( defined $dataobj )
        {
            push @ids, $dataobj->get_id;
        }
    }

    return EPrints::List->new( 
        dataset => $opts{dataset}, 
        session => $plugin->{session},
        ids=>\@ids );
}

sub contributors
{
    my( $plugin, $data, $node ) = @_;

    my @creators;

    foreach my $contributor ($node->childNodes)
    {
        next unless EPrints::XML::is_dom( $contributor, "Element" );

        my $creator_name = {};
        foreach my $part ($contributor->childNodes)
        {
            if( $part->nodeName eq "given_name" )
            {
                $creator_name->{given} = EPrints::Utils::tree_to_utf8($part);
            }
            elsif( $part->nodeName eq "surname" )
            {
                $creator_name->{family} = EPrints::Utils::tree_to_utf8($part);
            }
        }
        push @creators, { name => $creator_name }
            if exists $creator_name->{family};
    }

    $data->{creators} = \@creators if @creators;
}

sub convert_input
{
    my( $plugin, $data ) = @_;

    my $epdata = {};
    my $use_prefix = $plugin->param( "use_prefix" ) || 1;
    my $doi_field = $plugin->param( "doi_field" ) || "id_number";

    if( defined $data->{creators} )
    {
        $epdata->{creators} = $data->{creators};
    }
    elsif( defined $data->{author} )
    {
        $epdata->{creators} = [ 
            { 
                name=>{ family=>$data->{author} }, 
            } 
        ];
    }

    if( defined $data->{year} && $data->{year} =~ /^[0-9]{4}$/ )
    {
        $epdata->{date} = $data->{year};
    }

    if( defined $data->{"issn.electronic"} )
    {
        $epdata->{issn} = $data->{"issn.electronic"};
    }
    if( defined $data->{"issn.print"} )
    {
        $epdata->{issn} = $data->{"issn.print"};
    }
    if( defined $data->{"doi"} )
    {
        #Use doi field identified from config parameter, in case it has been customised. Alan Stiles, Open University 20140408
        my $doi = EPrints::DOI->parse( $data->{"doi"} );
	if( $doi )
	{
	    $epdata->{$doi_field} = $doi->to_string( noprefix=>!$use_prefix );
	    $epdata->{official_url} = $doi->to_uri->as_string;
	}
	else
	{
	    $epdata->{$doi_field} = $data->{"doi"};
	}
    }
    if( defined $data->{"volume_title"} )
    {
        $epdata->{book_title} = $data->{"volume_title"};
    }


    if( defined $data->{"journal_title"} )
    {
        $epdata->{publication} = $data->{"journal_title"};
    }
    if( defined $data->{"article_title"} )
    {
        $epdata->{title} = $data->{"article_title"};
    }


    if( defined $data->{"series_title"} )
    {
        # not sure how to map this!
        # $epdata->{???} = $data->{"series_title"};
    }


    if( defined $data->{"isbn"} )
    {
        $epdata->{isbn} = $data->{"isbn"};
    }
    if( defined $data->{"volume"} )
    {
        $epdata->{volume} = $data->{"volume"};
    }
    if( defined $data->{"issue"} )
    {
        $epdata->{number} = $data->{"issue"};
    }

    if( defined $data->{"first_page"} )
    {
        $epdata->{pagerange} = $data->{"first_page"};
    }
    if( defined $data->{"last_page"} )
        {
                $epdata->{pagerange} = "" unless defined $epdata->{pagerange};
                $epdata->{pagerange} .= "-" . $data->{"last_page"};
        }

    if( defined $data->{"doi.conference_paper"} )
    {
        $epdata->{type} = "conference_item";
    }
    if( defined $data->{"doi.journal_article"} )
    {
        $epdata->{type} = "article";
    }

    return $epdata;
}

sub url_encode
{
        my ($str) = @_;
        $str =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
        return $str;
}

1;

=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2021 University of Southampton.
EPrints 3.4 is supplied by EPrints Services.

http://www.eprints.org/eprints-3.4/

=for COPYRIGHT END

=for LICENSE BEGIN

This file is part of EPrints 3.4 L<http://www.eprints.org/>.

EPrints 3.4 and this file are released under the terms of the
GNU Lesser General Public License version 3 as published by
the Free Software Foundation unless otherwise stated.

EPrints 3.4 is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with EPrints 3.4.
If not, see L<http://www.gnu.org/licenses/>.

=for LICENSE END


