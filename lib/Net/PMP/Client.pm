package Net::PMP::Client;
use Mouse;
use Carp;
use Data::Dump qw( dump );
use LWP::UserAgent;
use HTTP::Request;
use MIME::Base64;
use JSON;
use Net::PMP::AuthToken;
use Net::PMP::CollectionDoc;

use Mouse::Util::TypeConstraints;
subtype 'LWPUA' => as 'Object' => where { $_->isa('LWP::UserAgent') };
no Mouse::Util::TypeConstraints;

our $VERSION = '0.01';

has 'host' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
    default  => 'https://api-sandbox.pmp.io/',
);
has 'id'     => ( is => 'rw', isa => 'Str',   required => 1, );
has 'secret' => ( is => 'rw', isa => 'Str',   required => 1, );
has 'debug'  => ( is => 'rw', isa => 'Bool',  default  => 0, );
has 'ua'     => ( is => 'rw', isa => 'LWPUA', builder  => '_init_ua', );
has 'auth_endpoint' =>
    ( is => 'rw', isa => 'Str', default => 'auth/access_token', );

# some constructor-time setup
sub BUILD {
    my $self = shift;
    $self->{host} .= '/' unless $self->host =~ m/\/$/;
    $self->{_last_token_ts} = 0;
    $self->get_token();    # initiate connection
    return $self;
}

sub _init_ua {
    my $self = shift;
    return LWP::UserAgent->new( agent => 'net-pmp-perl-' . $VERSION );
}

__PACKAGE__->meta->make_immutable;

=head1 NAME

Net::PMP::Client - Perl client for the Public Media Platform

=head1 SYNOPSIS

 use Net::PMP::Client;
 
 my $host = 'https://api-sandbox.pmp.io';
 my $client_id = 'i-am-a-client';
 my $client_secret = 'i-am-a-secret';

 # instantiate a client
 my $client = Net::PMP::Client->new(
     host   => $host,
     id     => $client_id,
     secret => $client_secret,
 ) or die "Can't connect to server $host: " . $Net::PMP::Client::Error;

 # authenticate
 my $token = $client->get_token();
 if ($token->expires_in() < 10) {
     die "Access token expires too soon. Not enough time to make a request. Mayday, mayday!";
 }
 printf("PMP token is: %s\n, $token->as_string());

 
=cut

=head1 DESCRIPTION

Net::PMP::Client is a Perl client for the Public Media Platform API (http://pmp.io/).

=head1 METHODS

=head2 get_token([I<refresh>])

Returns a Net::PMP::AuthToken object. The optional I<refresh> boolean indicates
that the Client should ignore any cached token and fetch a fresh one.

=cut

sub get_token {
    my $self = shift;
    my $refresh = shift || 0;

    # use cache?
    if ( !$refresh and $self->{_token} ) {
        my $tok = $self->{_token};
        if ( $self->{_last_token_ts} ) {
            $tok->expires_in(
                $tok->expires_in - ( time() - $self->{_last_token_ts} ) );
        }
        $self->{_last_token_ts} = time();
        return $tok;
    }

    # fetch new token
    my $uri     = $self->host . $self->auth_endpoint;
    my $request = HTTP::Request->new( GET => $uri );
    my $hash    = encode_base64( join( ':', $self->id, $self->secret ), '' );
    $request->header( 'Authorization' => 'CLIENT_CREDENTIALS ' . $hash );
    my $response = $self->ua->request($request);
    $self->debug and warn "GET $uri\n" . dump($response);

    if ( $response->code != 200 ) {
        croak "Invalid response from authn server: " . $response->status_line;
    }

    # unpack response
    my $token;
    eval { $token = decode_json( $response->decoded_content ); };
    if ($@) {
        croak "Invalid authn response: " . $response->decoded_content;
    }
    $self->{_token}         = Net::PMP::AuthToken->new($token);
    $self->{_last_token_ts} = time();
    return $self->{_token};
}

=head2 revoke_token

Expires the currently active AuthToken.

=cut

sub revoke_token {
    my $self    = shift;
    my $uri     = $self->host . $self->auth_endpoint;
    my $hash    = encode_base64( join( ':', $self->id, $self->secret ), '' );
    my $request = HTTP::Request->new( DELETE => $uri );
    $request->header( 'Authorization' => 'CLIENT_CREDENTIALS ' . $hash );
    my $response = $self->ua->request($request);
    $self->debug and warn "DELETE $uri\n" . dump($response);
    if ( $response->code != 204 ) {
        croak "Invalid response from authn server: " . $response->status_line;
    }
    $self->{_token} = undef;
    return $self;
}

=head2 get(I<uri>)

Issues a GET request on I<uri> and decodes the JSON response into a Perl
scalar. Returns the decoded scalar.

=cut

sub get {
    my $self    = shift;
    my $uri     = shift or croak "uri required";
    my $request = HTTP::Request->new( GET => $uri );
    my $token   = $self->get_token();
    $request->header( 'Content-Type' => 'application/json' );
    $request->header( 'Authorization' =>
            sprintf( '%s %s', $token->token_type, $token->access_token ) );
    my $response = $self->ua->request($request);
    $self->debug and warn "GET $uri\n" . dump($response);

    # retry if 401
    if ( $response->code == 401 ) {
        $token = $self->get_token(1);
        $request->header( 'Authorization' =>
                sprintf( '%s %s', $token->token_type, $token->access_token )
        );
        $response = $self->ua->request($request);
        $self->debug and warn "retry GET $uri\n" . dump($response);
    }
    if ( $response->code != 200 or !$response->decoded_content ) {
        croak "Unexpected response for GET $uri: " . $response->status_line;
    }

    my $json;
    eval { $json = decode_json( $response->decoded_content ); };
    if ($@) {
        croak "Invalid JSON in response: $@ : " . $response->decoded_content;
    }
    return $json;
}

=head2 get_doc([I<uri>]) 

Returns a Net::PMP::CollectionDoc representing I<uri>. Defaults
to the API base endpoint if I<uri> is omitted.

=cut

sub get_doc {
    my $self = shift;
    my $uri = shift || $self->host;

    my $response = $self->get($uri);

    # convert JSON response into a CollectionDoc
    $self->debug and warn dump $response;

    my $doc = Net::PMP::CollectionDoc->new($response);

    return $doc;
}

1;

__END__

=head1 AUTHOR

Peter Karman, C<< <pkarman at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-net-pmp-client at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-PMP-Client>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::PMP::Client


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-PMP-Client>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-PMP-Client>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-PMP-Client>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-PMP-Client/>

=back


=head1 ACKNOWLEDGEMENTS

American Public Media and the Public Media Platform sponsored the development of this module.

=head1 LICENSE AND COPYRIGHT

Copyright 2013 American Public Media Group

See the LICENSE file that accompanies this module.

=cut
