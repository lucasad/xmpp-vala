libxmpp.so: xmpp.vala
	valac xmpp.vala --gir=Xmpp-0.1.gir --library Xmpp-0.1 --pkg libxml-2.0 --pkg gio-2.0 -X -fPIC -X -shared -o libxmpp.so -H xmpp.h
	g-ir-compiler -m Xmpp -l libxmpp -o Xmpp-0.1.typelib Xmpp-0.1.gir
