{ lib, stdenv, fetchurl, pkg-config, meson, ninja, python3, gtk3, glibmm, cairomm, pangomm, atkmm, libepoxy, gnome }:

stdenv.mkDerivation rec {
  pname = "gtkmm";
  version = "3.24.5";

  src = fetchurl {
    url = "mirror://gnome/sources/${pname}/${lib.versions.majorMinor version}/${pname}-${version}.tar.xz";
    sha256 = "1ri2msp3cmzi6r65ghwb8gfavfaxv0axpwi3q60nm7v8hvg36qw5";
  };

  outputs = [ "out" "dev" ];

  nativeBuildInputs = [ pkg-config meson ninja python3 ];
  buildInputs = [ libepoxy ];

  propagatedBuildInputs = [ glibmm gtk3 atkmm cairomm pangomm ];

  # https://bugzilla.gnome.org/show_bug.cgi?id=764521
  doCheck = false;

  passthru = {
    updateScript = gnome.updateScript {
      packageName = pname;
      attrPath = "${pname}3";
      versionPolicy = "odd-unstable";
      freeze = true;
    };
  };

  meta = with lib; {
    description = "C++ interface to the GTK graphical user interface library";

    longDescription = ''
      gtkmm is the official C++ interface for the popular GUI library
      GTK.  Highlights include typesafe callbacks, and a
      comprehensive set of widgets that are easily extensible via
      inheritance.  You can create user interfaces either in code or
      with the Glade User Interface designer, using libglademm.
      There's extensive documentation, including API reference and a
      tutorial.
    '';

    homepage = "https://gtkmm.org/";

    license = licenses.lgpl2Plus;

    maintainers = with maintainers; [ raskin ];
    platforms = platforms.unix;
  };
}
