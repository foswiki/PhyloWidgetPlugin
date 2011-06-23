package Foswiki::Plugins::PhyloWidgetPlugin;

# Always use strict to enforce variable scoping
use strict;
use warnings;

use Carp;
use Foswiki::Func    ();    # The plugins API
use Foswiki::Plugins ();    # For the API version
use Foswiki::Sandbox;

use Error::Simple;
use Error qw(:try);
use IO::String;

use Bio::NexmlIO;
use Bio::TreeIO;
use Bio::NEXUS;
use Bio::Tree::Draw::Cladogram;

require LWP::UserAgent;

our $VERSION = '$Rev$';

our $RELEASE = '0.1.2';

our $SHORTDESCRIPTION =
  'A Foswiki integration of the PhyloWidget phylogeny browser';

our $NO_PREFS_IN_TOPIC = 1;

my $pubUrlPath;
my $hostUrL;
my $baseWeb;
my $baseTopic;

# return Foswiki::expandStandardEscapes($text);

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.0 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        return 0;
    }
    $pubUrlPath = Foswiki::Func::getPubUrlPath();
    $hostUrL    = Foswiki::Func::getUrlHost();

    # Example code of how to get a preference value, register a macro
    # handler and register a RESTHandler (remove code you do not need)

    # Set your per-installation plugin configuration in LocalSite.cfg,
    # like this:
    # $Foswiki::cfg{Plugins}{PhyloWidgetPlugin}{ExampleSetting} = 1;
    # See %SYSTEMWEB%.DevelopingPlugins#ConfigSpec for information
    # on integrating your plugin configuration with =configure=.

 # Always provide a default in case the setting is not defined in
 # LocalSite.cfg.
 # my $setting = $Foswiki::cfg{Plugins}{PhyloWidgetPlugin}{ExampleSetting} || 0;

    # Register the _EXAMPLETAG function to handle %EXAMPLETAG{...}%
    # This will be called whenever %EXAMPLETAG% or %EXAMPLETAG{...}% is
    # seen in the topic text.
    Foswiki::Func::registerTagHandler( 'PHYLOWIDGET', \&_EXAMPLETAG );
    Foswiki::Func::registerTagHandler( 'NEXUSTREES',  \&LISTNEXUSTREES );
    Foswiki::Func::registerTagHandler( 'TREEPNG',     \&TREEPNG );
    $baseWeb   = $web;
    $baseTopic = $topic;

    # Allow a sub to be called from the REST interface
    # using the provided alias
    Foswiki::Func::registerRESTHandler( 'getNHX',       \&getNHXfromNEX );
    Foswiki::Func::registerRESTHandler( 'processClade', \&processClade );
    Foswiki::Func::registerRESTHandler( 'getPNG',       \&getPNG );

    # Plugin correctly initialized
    return 1;
}

sub LISTNEXUSTREES {
    my ( $session, $params, $Atopic, $Aweb, $topicObject ) = @_;
    my @format = ();
    my $url =
      getAttachUrl( '', $params->{'_DEFAULT'}, $params->{'attachment'} );
    my $web;
    my $topic;
    my $attachment = $params->{'attachment'};
    my $content;

    ( $web, $topic ) =
      Foswiki::Func::normalizeWebTopicName( '', $params->{'_DEFAULT'} );
    $content = Foswiki::Func::readAttachment( $web, $topic, $attachment );

    my $nexus = Bio::NEXUS->new();

    if ($content) {
        $nexus->read( { format => 'string', 'param' => $content } )
          ;    # or whatever\
        my @trees      = @{ $nexus->get_block("trees")->get_trees() };
        my $treeNumber = $#trees;

        foreach my $treeid ( ( 0 .. $treeNumber ) ) {
            my $tree     = $trees[$treeid];
            my $treeName = $tree->get_name();
            $treeName =~ s/_/ /gx;
            my $format = $params->{format};
            $format =~ s/\$treeid\b/$treeid/gx;
            $format =~ s/\$treeName\b/$treeName/gx;
            push @format, $format if $format;
        }

        return Foswiki::expandStandardEscapes( $params->{header}
              . join( $params->{separator}, @format )
              . $params->{footer} );
    }
    else {
        return "The resource is not available online.";
    }
}

sub getAttachUrl {

    my ( $web, $topic, $attachment ) = @_;

    ( $web, $topic ) = Foswiki::Func::normalizeWebTopicName( $web, $topic );
    return Foswiki::Func::getUrlHost() . "$pubUrlPath/$web/$topic/$attachment";
}

sub getNHXfromNEX {
    my ( $session, $subject, $verb, $responses ) = @_;
    my $requestObject;
    if ( defined &Foswiki::Func::getRequestObject ) {
        $requestObject = Foswiki::Func::getRequestObject();
    }
    else {
        $requestObject = Foswiki::Func::getCgiQuery();
    }
    my $web   = $requestObject->param('web');
    my $topic = $requestObject->param('topic');

    my $attachment = $requestObject->param('attachment');
    my $tree       = $requestObject->param('tree');
    my $url        = getAttachUrl( $web, $topic, $attachment );

    my $nexus = Bio::NEXUS->new();
    my $atree;
    my $content;

    $content = Foswiki::Func::readAttachment( $web, $topic, $attachment );

    if ($content) {
        eval {

            $nexus->read( { format => 'string', 'param' => $content } );
        } or croak return "error loading nexus into object $_ $@";

        eval {
            $atree =
              @{ $nexus->get_block("trees")->get_trees() }[$tree]->as_string();
        } or croak return "ERROR: Index out of range.";

        return $atree;

    }
    else {
        return "The resource is not available online.";
    }
}

sub formatClade {
    my ($clade) = @_;
    my $io = IO::String->new($clade);

    my $treeObj = Bio::TreeIO->new( -fh => $io, -format => 'newick' );
    my $tree = $treeObj->next_tree;
    my @list;
    for my $leaf ( $tree->get_leaf_nodes ) {
        push( @list, $leaf->id );
    }
    return join( ',', @list );

}

sub processClade {
    my $requestObject;
    my $web;
    my $topic;
    my $clade;
    my $request;
    my $updatetopic;
    my $newtopicname;
    my $count;
    my $includeText;
    my $text;
    my $c;
    my $phylo;
    my $genus;
    my $section;
    my $filename = "Temi";
    my $makeTree;
    my ( $debug, $dinfo );
    $debug = 1;
    $dinfo = '';

    if ( defined &Foswiki::Func::getRequestObject ) {
        $requestObject = Foswiki::Func::getRequestObject();
    }
    else {
        $requestObject = Foswiki::Func::getCgiQuery();
    }

    #   eval{
    # initialization of variables
    $web   = $requestObject->param("theweb");
    $topic = $requestObject->param("thetopic");
    $clade = $requestObject->param("clade");
    $phylo = $requestObject->param("phylo");
    $genus = $requestObject->param("genus");

    #clean nhx annotations since it is not working
    $clade =~ s/\[[^\]]*\]//g;

    # convert to integer for easier comparison
    if ( $phylo eq 'true' ) {
        $makeTree = 1;
    }
    else {
        $makeTree = 0;
    }

    # convert nexus to list format
    if ( !$makeTree ) {
        $clade = formatClade($clade);
    }

    #  my($meta,$text) = Foswiki::Func::readTopic("System","VarPHYLOWIDGET");

    #   read current topic and get the count variable
    ( $updatetopic, $text ) = Foswiki::Func::readTopic( $web, $topic );
    $c = $updatetopic->get( 'FIELD', 'count' );
    if ( !$c ) {
        $count = 0;
    }
    else {
        $count = $c->{value};
    }

    #@c = $updatetopic->get('FIELD');
    #my @arr = keys %c;
    #@arr = $updatetopic->find('FIELD');
    #$c = $count;
    $count        = $count + 1;
    $newtopicname = "$web$topic$count";

    #incase of subwebs
    $newtopicname =~ s/\///g;
    $section = "Request";

    # appropriate content for the new topic
    if ($makeTree) {
        $request =
"\n---+++ $section\n%PHYLOWIDGET{tree=\"%PUBURL%/%WEB%/%TOPIC%/selection.txt\" useBranchLengths=\"true\"}%";

        #     $request = $clade;

    }
    else {
        $request =
"\n---+++ $section\n%STARTSECTION{\"$section\"}%%INCLUDE{\"System.CharacterGridView\"}%
<!--
   * Set recipe = %URLPARAM{\"cTopic\" default=\"NONE\"}%
-->";
    }
    if ($debug) {
        $dinfo = $dinfo . 'created text\n';
    }

    #   creating and saving new topic
    my ($newtopic) = Foswiki::Func::readTopic( $web, $newtopicname );
    $newtopic->text($request);
    $newtopic->putKeyed( 'TOPICPARENT', { name => "$topic" } );
    $newtopic->save();
    $newtopic->finish();
    if ($debug) {
        $dinfo = $dinfo . 'created clade topic\n';
    }

    # save attachment in the new topic
    my $attach = tempFileName();

    #try{
    my $fh;

    # create temp file
    open $fh, '>' . $attach;
    print $fh $clade;
    close $fh;

    my @st   = stat $attach;
    my $size = $st[7];
    my $date = $st[9];

    #     save as attachment
    Foswiki::Func::saveAttachment(
        $web,
        $newtopicname,
        'selection.txt',
        {
            file     => $attach,
            filesize => $size,
            filedate => $date,
        }
    );
    unlink $attach if ( $attach && -e $attach );

    #  }
    #  otherwise{
    #  };
    #  $includeText ="%INCLUDE{\"$web.$newtopicname\"}%";
    #  $updatetopic->text($text);

    # update current topic
    $includeText = "\n---+++ $section $count\nSee [[$newtopicname]]";
    $updatetopic->text("$text $includeText");
    $updatetopic->putKeyed( 'FIELD',
        { name => 'count', title => 'number of requests', value => "$count" } );
    $updatetopic->save();
    $updatetopic->finish();
    if ($debug) {
        $dinfo = $dinfo . 'updated parent topic\n';
    }

    # convert clade into nexml format
    if ($makeTree) {
        if ($debug) {
            $dinfo = $dinfo . 'in nexml conversion block\n';
        }

        # create file in work area
        $filename = tempFileName();

        #     $filename = Foswiki::Func::getWorkArea('PhyloWidgetPlugin');
        #     $filename = $filename.'/nexml'.int( rand(1000000000) ).'.xml';
        # read clade from the string
        my $io = IO::String->new($clade);
        my $treeio = Bio::TreeIO->new( -fh => $io, -format => 'nhx' );

        # write clade into a file in nexml format
        my $tree      = $treeio->next_tree;
        my @treeArray = ();
        push( @treeArray, $tree );
        my $treeO =
          Bio::TreeIO->new( -file => '>' . $filename, format => 'nexml' );
        $treeO->write_tree($tree);
        $treeO->DESTROY;
        if ($debug) {
            $dinfo = $dinfo . 'wrote the tree into file\n';
        }

        #save the file as attachment
        my @stats    = stat $filename;
        my $fileSize = $stats[7];
        my $fileDate = $stats[9];
        if ($debug) {
            $dinfo = $dinfo . 'got info of file\n';
        }

        #    try {
        Foswiki::Func::saveAttachment(
            $web,
            $newtopicname,
            "nexml.xml",
            {
                file     => $filename,
                filesize => $fileSize,
                filedate => $fileDate,
            }
        );
        if ($debug) {
            $dinfo = $dinfo . 'linked nexml to new topic\n';
        }

        # delete temp file
        unlink($filename) if ( $filename && -e $filename );
        if ($debug) {
            $dinfo = $dinfo . 'deleted temp topic\n';
        }

        #     } catch Foswiki::AccessControlException with {
        # Topic CHANGE access denied
        #     if($debug){
        #	$dinfo = $dinfo. 'in access control exp\n';
        #	}
        #   } catch Error::Simple with {
        #     # see documentation on Error
        #    if($debug){
        #	$dinfo = $dinfo. 'in simple error\n';
        #	}
        #  }
        # otherwise {
        #  if($debug){
        #   $dinfo = $dinfo. 'in otherwise\n';
        #  }
        # }
    }

#  Foswiki::Func::saveTopic("Main","testing", $meta,$text,{ forcenewrevision => 1 });
# redirect to new topic
    my $redirect =
      Foswiki::Func::getScriptUrl( "System", "ViewGenusData", "view" );
    Foswiki::Func::redirectCgiQuery( undef,
        $redirect
          . "?aWeb=$web;aTopic=$newtopicname;aAttach=selection.txt;genus=$genus"
    );

    # return "$makeTree 1 $dinfo";
    #   }
    #   or do
    #   {
    #       return "PhyloWidgetError";
    # return "$@";
    # return $dinfo;
    #   };
}

# create temp file namespace
sub tempFileName {

    # create file in work area
    my $filename = Foswiki::Func::getWorkArea('PhyloWidgetPlugin');
    return $filename . '/nexml' . int( rand(1000000000) );
}

sub TREEPNG {
    my ( $session, $params, $Atopic, $Aweb, $topicObject ) = @_;
    my $rest = Foswiki::Func::getScriptUrl( undef, undef, 'rest' );
    my $topicURL =
      Foswiki::Func::getScriptUrl( 'System', 'PhyloNewickViewer', 'view' );
    my ( $width, $height ) = ( $params->{width}, $params->{height} );
    return
"<a href='$topicURL?qweb=$params->{web};qtopic=$params->{topic};qattach=$params->{attach}'><img src='$rest/PhyloWidgetPlugin/getPNG?qweb=$params->{web};qtopic=$params->{topic};qattach=$params->{attach};rev=4;' height='$height' width='$width'/></a>";

}

sub getPNG {
    my ( $session, $subject, $verb, $responses ) = @_;
    my $request;
    if ( defined &Foswiki::Func::getRequestObject ) {
        $request = Foswiki::Func::getRequestObject();
    }
    else {
        $request = Foswiki::Func::getCgiQuery();
    }
    my ( $web, $topic ) =
      ( $request->param('qweb'), $request->param('qtopic') );
    my $filename = $request->param('qattach');
    my $rev      = $request->param('rev');
    my $width    = $request->param('width');
    my $height   = $request->param('height');
    my $margin   = $request->param('margin');
    my $fontSize = $request->param('fontsize');
    my $format   = $request->param('format') || 'newick';
    ( $web, $topic ) = Foswiki::Func::normalizeWebTopicName( $web, $topic );

    #return $web.' '.$topic;
    #my $topicObject = Foswiki::Meta->new($session,$web,$topic);
    my $treeData =
      Foswiki::Func::readAttachment( $web, $topic, $filename, $rev );
    my $io    = IO::String->new($treeData);
    my $treei = Bio::TreeIO->new( -fh => $io, -format => $format );
    my $fh    = IO::String->new();
    my $treeo = Bio::TreeIO->new(
        -fh        => $fh,
        -format    => 'svggraph',
        -WIDTH     => $width,
        -HEIGHT    => $height,
        -MARGIN    => $margin,
        -FONT_SIZE => $fontSize
    );

    my $tree = $treei->next_tree();

    my $temp   = tempFileName();
    my $treeio = Bio::Tree::Draw::Cladogram->new(
        -bootstrap => 0,
        -tree      => $tree,
        -compact   => 1
    );
    $treeio->print( -file => $temp . '.eps' );
    my $response = $session->{response};
    $response->header( -type => 'image/png', -status => '200' );
    use Image::Magick;
    my $image = Image::Magick->new();
    $image->read("$temp.eps");
    my @blob = $image->ImageToBlob( magick => 'PNG' );
    undef $image;
    unlink $temp if ( $temp && -e $temp );
    return join( '', @blob );
}

# The function used to handle the %EXAMPLETAG{...}% macro
# You would have one of these for each macro you want to process.
sub _EXAMPLETAG {
    my ( $session, $params, $topic, $web, $topicObject ) = @_;

    use Data::Dumper;

    my @str = ();

    my $url      = '';
    my @tree     = ();
    my $theweb   = '';
    my $thetopic = '';
    my $attach   = '';
    my $webName  = $Foswiki::SESSION->{webName};
    my $genus    = $params->{genus} || '';
    $url = $params->{'_DEFAULT'};
    ( $theweb, $thetopic ) =
      Foswiki::Func::normalizeWebTopicName( $webName, $url );

    if ( $params->{'_DEFAULT'} && $params->{'attachment'} ) {

        my $host = Foswiki::Func::getUrlHost();

        $attach = $params->{'attachment'};
        push @tree, "tree:'$host/$pubUrlPath/$theweb/$thetopic/$attach'";
    }
    elsif ( $params->{'_DEFAULT'} ) {

        my $theurl = Foswiki::Func::getViewUrl( $theweb, $thetopic );
        push @tree, "tree:'$theurl?phylofixamps=1;template=phylonhx'"
          if $theurl;
    }
    elsif ( $params->{'url'} ) {

        push @tree, "tree:'$params->{'url'}'" if $params->{'url'};
    }
    while ( my ( $key, $value ) = each( %{$params} ) ) {
        push( @tree, "$key: '$value'" )
          if ( $key ne "_RAW" )
          and ( $key ne "_DEFAULT" )
          and ( $key ne "url" );
    }

    Foswiki::Func::addToZone(
        "script",
        "PhyloWidgetPlugin/Javascript",
        "<style>
	#phylowidgetobject { padding: 0.5em; }
        #phylowidgetobject h3 { text-align: center; margin: 0; }
	.ui-resizable-helper { border: 2px dotted #00F; }
	</style>"
          . "<script src='$pubUrlPath/$Foswiki::cfg{SystemWebName}/PhyloWidgetPlugin/scripts/phylowidget.js'></script>"
          . "<script>PhyloWidget.codebase = '$hostUrL$pubUrlPath/$Foswiki::cfg{SystemWebName}/PhyloWidgetPlugin/lib';</script>"
    );

    # add the function that will interface with processClade rest handler
    my $mobbs = '%INCLUDE{"System.VarPHYLOWIDGET" section="jscode"}%';
    $mobbs = Foswiki::Func::expandCommonVariables($mobbs);
    $mobbs =~ s/\$genus/$genus/g;
    Foswiki::Func::addToZone( 'script', 'jscode',
        '<script>' . $mobbs . '</script>', 'JQUERY' );

    # add a form to the returned text
    my $form = '%INCLUDE{"System.VarPHYLOWIDGET" section="cladeform"}%';

    #   $form = Foswiki::Func::addToZone('','','');

    my $height = $params->{'height'} + 6;
    my $width  = $params->{'width'} + 6;
    my $param  = join ',', @tree;
    return
"<div id = 'phylowidgetobject' style='width: $width; height: $height; border: 2px solid; padding: 3px;display:inline-table'><script>PhyloWidget.writeWidget({$param});</script> $form</div>";
}

=begin TML

---++ postRenderingHandler( $text )
   * =$text= - the text that has just been rendered. May be modified in place.

*NOTE*: This handler is called once for each rendered block of text i.e. 
it may be called several times during the rendering of a topic.

*NOTE:* meta-data is _not_ embedded in the text passed to this
handler.

*NOTE:* Read the developer supplement at
Foswiki:Development.AddToZoneFromPluginHandlers if you are calling
=addToZone()= from this handler

Since Foswiki::Plugins::VERSION = '2.0'

=cut

sub postRenderingHandler {
    my $requestObject;

    if ( defined &Foswiki::Func::getRequestObject ) {
        $requestObject = Foswiki::Func::getRequestObject();
    }
    else {
        $requestObject = Foswiki::Func::getCgiQuery();
    }

    # You can work on $text in place by using the special perl
    # variable $_[0]. These allow you to operate on $text
    # as if it was passed by reference; for example:
    if ( Foswiki::Func::isTrue( $requestObject->param('phylofixamps'), 0 ) ) {
        use HTML::Entities;
        decode_entities( $_[0] );
    }

    return;
}
1;
