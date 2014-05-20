/*
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
*/

namespace Xmpp {
	public class Client : Object {
		public string server { get; construct; }
		public string jid { get; private set; }

		private string streamTxt;
		private Xml.Node streamTag;


		private MainContext main_context;
		private IOStream ios;
		private Xml.ParserCtxt xmlin;
		private Xml.SaveCtxt xmlout;



		public signal void authorize(List<string> mechanisms);
		public signal void message(Xml.Node message);

		public Client(string server, MainContext? context=null) {
			Object(server: server);
			main_context = context;
			streamTxt = "<stream:stream to=\"%s\" xml:lang=\"en\" version=\"1.0\" xmlns:stream=\"http://etherx.jabber.org/streams\" xmlns=\"jabber:client\">\n".printf(server);

			Xml.Ns *stream_ns = new Xml.Ns(null, "http://etherx.jabber.org/streams", "stream");
			streamTag = new Xml.Node(stream_ns, "stream");
			streamTag.new_ns("http://etherx.jabber.org/streams", "stream");
			streamTag.new_ns("jabber:client", null);
			streamTag.new_prop("to", server);
			streamTag.new_prop("version", "1.0");

			xmlin = new Xml.ParserCtxt.create_push(&saxHandler, this, (char[])"", 0);
			xmlout = new Xml.SaveCtxt.to_io((ctx, buffer, len) => {
					var output_stream = ((Client) ctx).ios.output_stream;
					if(len == 0)
						return 0;
					buffer.length = len;
					return (int)output_stream.write((uint8[])buffer);
				},
				(context) => 0,
				this);

			iqs = new HashTable<int64?,iqr*>(int64_hash,int64_equal);
			debug = false;
		}

		internal bool debug;

		public void send(Xml.Node node) {
			assert(xmlout != null);
			xmlout.save_tree(node);
			xmlout.flush();
		}

		public void send_raw(string stanza) {
			size_t len;
			ios.output_stream.write_all(stanza.data, out len);
		}

		internal bool tls_started;
		internal PollableSource source;

		private void starttls() {
			if(tls_started)
				return;

			source.destroy();
			source = null;
			var tls_connection = TlsClientConnection.new(ios, null);
			tls_connection.handshake();
			ios = (IOStream) tls_connection;

			source = ((PollableInputStream) tls_connection.input_stream).create_source();
			source.set_callback((stream) => {
					uint8[4096] buf = new uint8[4096];
					try {
						int len = (int) ios.input_stream.read(buf);
						buf[len] = 0;

						xmlin.parse_chunk((char[])buf, len, false);
					} catch(GLib.Error e) {
						return false;
					}
					return true;
				});
			source.attach(main_context);
			send_raw(streamTxt);
		}

		static const string starttlsTag = "<starttls xmlns=\"urn:ietf:params:xml:ns:xmpp-tls\"/>\n";
		public new void sconnect() {
			SocketClient client = new SocketClient();
			client.set_enable_proxy(false);

			ios = (IOStream) client.connect_to_service(server, "xmpp-client");
			assert(ios != null);

			source  = ((PollableInputStream) ios.input_stream).create_source();
			source.set_callback((stream) => {
					uint8[4096] buf = new uint8[4096];
					int len = (int) ios.input_stream.read(buf);
					xmlin.parse_chunk((char[])buf, len, false);
					return true;
				});
			source.attach(main_context);
			send_raw(streamTxt);
		}
		~Client() {

		}

		internal Xml.Node* stream;
		internal Xml.Node* current;

		private static void start_element_ns(void* ctx, string localname, string? prefix, string URI, int nb_namespaces, string[] namespaces, int nb_attributes, int nb_defaulted, string[] attributes) {
			Client self = (Client)ctx;

			Xml.Ns* node_ns = new Xml.Ns(null, URI.dup(), null);
			Xml.Node* current = new Xml.Node(node_ns, localname);

			int i;
			for(i=0;i<nb_namespaces;++i) {
				current->new_ns(namespaces[i*2+1], namespaces[i*2]);
			}
			int indexAttr = 0;
			for (i=0;
				 indexAttr < nb_attributes;
				 ++indexAttr, i += 5 )
			{
				string name = attributes[i];
				string nsPrefix = attributes[i+1];
				string nsUri = attributes[i+2];

				string valueB = attributes[i+3];
				string valueE = attributes[i+4];
				string value = valueB.slice(0, valueB.length-valueE.length);

				current->new_ns_prop(new Xml.Ns(current, nsUri, nsPrefix),
									 name,
									 value);
			}

			if("stream" == localname) {
				if(self.stream != null)
					delete self.stream;
				self.stream = current;
				return;
			}

			if(self.current != null)
				self.current->add_child(current);
			self.current = current;
		}

		private static void end_element_ns(void* ctx, string localname, string? prefix, string URI) {
			Client self = (Client)ctx;

			var current = self.current;
			if(current == null)
				return;

			self.current = current->parent;

			if(self.current == null) {
				self.process(current);
			}
		}

		private static void sax_characters(void *ctx, string chunk, int length) {
			Client self = (Client)ctx;
			self.current->add_content_len(chunk, length);
		}

		static Xml.SAXHandler saxHandler = Xml.SAXHandler() {
			initialized = (uint)0xDEEDBEAF, // SAX2_MAGIC
			startElementNs = start_element_ns,
			endElementNs = end_element_ns,
			characters = sax_characters
		};

		static const string NS_STREAMS = "http://etherx.jabber.org/streams";
		static const string NS_TLS = "urn:ietf:params:xml:ns:xmpp-tls";
		static const string NS_CLIENT = "jabber:client";
		public static const string NS_SASL = "urn:ietf:params:xml:ns:xmpp-sasl";

		internal void process(Xml.Node node) {
			stdout.printf("Processing <%s/>\n", node.name);

			switch(node.ns->href) {
			case NS_CLIENT:
				switch(node.name) {
				case "iq":
					var id = int64.parse(node.get_prop("id"));
					var cb = iqs.get(id);
					iqs.remove(id);
					cb.node = node;
					cb.run();
					break;
				case "message":
					Idle.add(() => {
							message(node);
							return false;
						});
					break;
				}
				break;
			case NS_STREAMS:
				switch(node.name) {
				case "features":
					process_features(node);
					break;
				case "error":
					stdout.printf("Houston, we have a problem: '%s'\n", node.get_content());
					break;
				default:
					stdout.printf("MISC NS_STREAM <%s/>\n", node.name);
					break;
				}
				break;
			case NS_TLS:
				assert(node.name == "proceed");
				starttls();
				break;
			case NS_SASL:
				switch(node.name) {
				case "success":
					stdout.puts("Authentication successful\n");
					xmlout.save_tree(streamTag);
					xmlout.flush();
					break;
				case "failure":
					stdout.puts("Failed to authenticate: %s\n");
					break;
				}
				break;
			default:
				stdout.printf("TODO: ADD THIS <%s xmlns=\"%s\"/>\n", node.name, node.ns->href);
				break;
			}
		}

		private void process_features(Xml.Node node) {
			for (Xml.Node* iter = node.children; iter != null; iter = iter->next) {
				switch(iter->name) {
				case "starttls":
					if(tls_started)
						break;
					send_raw(starttlsTag);
					return;
				case "mechanisms":
					assert(iter->ns->href == NS_SASL);
					var mechanisms = new List<string>();
					for (Xml.Node* mechanism = iter->children; mechanism != null; mechanism = mechanism->next) {
						mechanisms.prepend(mechanism->get_content());
					}
					authorize(mechanisms);
					send_raw(streamTxt);
					return;
				case "bind":
					send_iq_set_raw.begin("<bind xmlns=\"urn:ietf:params:xml:ns:xmpp-bind\" />", server, (res,a) => {
							unowned Xml.Node iq = send_iq_set_raw.end(a);
							assert("result" == iq.get_prop("type"));
							jid = iq.children->get_content();
						});
					break;
				case "session":
					send_iq_set_raw.begin("<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>", server, (res, a) => {
							unowned Xml.Node iq = send_iq_set_raw.end(a);
							assert("result" == iq.get_prop("type"));
							Idle.add( () => {
									session_start();
									return false;
								});
						});
					break;
				default:
					stdout.printf("Feature UNKN: <%s/>, val: %s\n", iter->name,iter->get_content());
					break;
				}
			}
		}

		public signal void session_start();


		internal struct iqr {
			public unowned SourceFunc cb;
			public unowned Xml.Node node;
			public void run() {
				cb();
			}
		}

		private HashTable<int64?,iqr*> iqs;

		private int64 seq;
		public async unowned Xml.Node send_iq_set_raw(string data, string to=server) {
			var id = ++seq;
			send_raw("<iq type=\"set\" id=\"%lli\" to=\"%s\">%s</iq>".printf(id,to,data));

			iqr r = iqr() {
				cb = send_iq_set_raw.callback
			};
			iqs.insert(id,&r);

			yield;
			return r.node;
		}
	}
}
