#!/usr/bin/env python2
"""
    This file is part of xmpp-vala.

    Foobar is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Foobar is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with xmpp-vala.  If not, see <http://www.gnu.org/licenses/>.
"""

from gi.repository import Xmpp,GLib
import libxml2
from sys import argv
from base64 import b64encode

def authorize(client, methods, ctx):
    for method in methods:
        print(method)

    auth = """<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" mechanism="PLAIN">%s</auth>""" % b64encode('\0'+argv[1]+'\0'+argv[2])

    client.send_raw(auth)

server = argv[1].split('@')[1]
client = Xmpp.Client.new(server, None)
client.sconnect()
client.connect('authorize', authorize, None)

def start(client, ctx):
    print("STarted session ok")

client.connect('session_start', start, 5)

GLib.MainLoop().run()
