use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Exception',
  VERSION_FROM => 'Exception.pm',
  dist => {
    COMPRESS => 'gzip',
    SUFFIX   => 'gz'
  }
);
