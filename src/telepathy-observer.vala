/*
 * Zeitgeist
 *
 * Copyright (C) 2012 Collabora Ltd.
 *               Authored by: Seif Lotfy <seif.lotfy@collabora.co.uk>
 * Copyright (C) 2012 Eslam Mostafa <cseslam@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

using Zeitgeist;
using TelepathyGLib;
using Json;

public class TelepathyObserver : DataProvider
{

  private const string actor = "dbus://org.freedesktop.Telepathy.Logger.service";
  private const string tp_account_path = "x-telepathy-account-path:%s";
  private const string tp_identifier = "x-telepathy-identifier:%s";
  private const string ft_json_domain = "http://zeitgeist-project.com/1.0/telepathy/filetransfer";
  private const string call_json_domain = "http://zeitgeist-project.com/1.0/telepathy/call";

  private TelepathyGLib.DBusDaemon dbus = null;
  private TelepathyGLib.AutomaticClientFactory factory = null;
  private TelepathyGLib.SimpleObserver observer = null;
  private HashTable<string, Timer> call_timers = null;

  public TelepathyObserver (DataHub datahub) throws GLib.Error
  {
    GLib.Object (unique_id: "com.zeitgeist-project,datahub,telepathy-observer",
                 name: "Telepathy Observer",
                 description: "Logs IM, call and filetransfer from telepathy",
                 datahub: datahub);
  }
  
  construct
  {
    call_timers = new HashTable<string, Timer> (str_hash, str_equal);
    dbus = TelepathyGLib.DBusDaemon.dup ();
    factory = new TelepathyGLib.AutomaticClientFactory (dbus);

    Quark[] channel_quark = {TelepathyGLib.Channel.get_feature_quark_contacts ()};
    TelepathyGLib.ContactFeature[] contact_quark = {TelepathyGLib.ContactFeature.ALIAS};

    factory.add_channel_features (channel_quark);
    factory.add_contact_features (contact_quark);
  }

  // if vala didn't have bug in construct-only properties, the properties
  // would be construct-only
  public override string unique_id { get; construct set; }
  public override string name { get; construct set; }
  public override string description { get; construct set; }

  public override DataHub datahub { get; construct set; }
  public override bool enabled { get; set; default = true; }
  public override bool register { get; construct set; default = true; }

  private void push_event (Event event)
  {
    /*stdout.printf("Event:\n");
    stdout.printf("    - timestamp:%s\n", (string)event.get_timestamp ());
    stdout.printf("    - actor:%s\n", event.get_actor ());
    stdout.printf("    - interpretation:%s\n", event.get_interpretation ());
    stdout.printf("    - manifestation:%s\n", event.get_manifestation ());
    stdout.printf("    - origin:%s\n", event.get_origin ());
    stdout.printf("    - subjects:%i\n", event.num_subjects ());
    for (var i=0; i<event.num_subjects (); i++)
    {
      var subject = event.get_subject(i);
      stdout.printf("    - subjects: %i\n", i);
      stdout.printf("         - uri: %s\n", subject.get_uri ());
      stdout.printf("         - interpretation: %s\n", subject.get_interpretation ());
      stdout.printf("         - manifestation: %s\n", subject.get_manifestation ());
      stdout.printf("         - mimetype: %s\n", subject.get_mimetype ());
      stdout.printf("         - origin: %s\n", subject.get_origin ());
      stdout.printf("         - text: %s\n", subject.get_text ());
      stdout.printf("         - storage: %s\n", subject.get_storage ());
    }
    if (event.get_payload() != null)
      stdout.printf("    - payload:%s\n", (string) event.get_payload().data);
    */
    GenericArray<Event> events = new GenericArray<Event> ();
    events.add (event);
    items_available (events);
  }

  private Event create_text_event (Account account, Channel channel)
  {
    var target = channel.get_target_contact ();
    var obj_path = account.get_object_path ();
    obj_path = this.tp_account_path.printf(obj_path[TelepathyGLib.ACCOUNT_OBJECT_PATH_BASE.length:
                 obj_path.length]);
    Event event_template = new Event.full (
                              ZG_ACCESS_EVENT,
                              ZG_USER_ACTIVITY,
                              this.actor,
                              null,
                              null);
    event_template.set_origin (obj_path);
    if (!channel.requested)
      event_template.set_manifestation (ZG_WORLD_ACTIVITY);
    // Create IM subject for the event
    event_template.add_subject (
      new Subject.full (
        "",
        NMO_IMMESSAGE,
        NFO_SOFTWARE_SERVICE,
        "plain/text",
        this.tp_identifier.printf(target.get_identifier ()),
        target.get_alias (),
        "net")
      );
    // Create Contact subject for the event
    event_template.add_subject (
      new Subject.full (
        this.tp_identifier.printf(target.get_identifier ()),
        NCO_CONTACT,
        NCO_CONTACT_LIST_DATA_OBJECT,
        "",
        this.tp_identifier.printf(target.get_identifier ()),
        target.get_alias (),
        "net")
    );
    return event_template;
  }

  private void observe_text_channel (SimpleObserver observer, Account account, 
                                 Connection connection, Channel b_channel,
                                 ChannelDispatchOperation? dispatch_operation,
                                 List<ChannelRequest> requests,
                                 ObserveChannelsContext context)
  {
    TextChannel channel = (TextChannel) b_channel;
    var target = channel.get_target_contact ();
    if (target != null)
    {
      var event_template = this.create_text_event (account, channel);
      this.push_event (event_template);
      foreach (var message in channel.get_pending_messages ())
      {
        if (!message.is_delivery_report ())
        {
          event_template = this.create_text_event (account, channel);
          event_template.set_interpretation (ZG_RECEIVE_EVENT);
          event_template.set_manifestation (ZG_WORLD_ACTIVITY);
          this.push_event (event_template);
        }
      }
      channel.invalidated.connect (() => {
        event_template = this.create_text_event (account, channel);
        event_template.set_interpretation (ZG_LEAVE_EVENT);
        this.push_event (event_template);
      });
      channel.message_received.connect (() => {
        event_template = this.create_text_event (account, channel);
        event_template.set_interpretation (ZG_RECEIVE_EVENT);
        event_template.set_manifestation (ZG_WORLD_ACTIVITY);
        this.push_event (event_template);
      });
      channel.message_sent.connect (() => {
        event_template = this.create_text_event (account, channel);
        event_template.set_interpretation (ZG_SEND_EVENT);
        event_template.set_manifestation (ZG_USER_ACTIVITY);
        this.push_event (event_template);
      });
    }
  }

  private Event? create_call_event (Account account, CallChannel channel)
  {
    var targets = channel.get_members ();
    if (targets == null)
    {
      return null;
    }
    var obj_path = account.get_object_path ();
    obj_path = this.tp_account_path.printf(obj_path [TelepathyGLib.ACCOUNT_OBJECT_PATH_BASE.length:
                 obj_path.length]);
    Event event_template = new Event.full (
                              ZG_ACCESS_EVENT,
                              ZG_USER_ACTIVITY,
                              this.actor,
                              null,
                              obj_path);
    if (!channel.requested)
      event_template.set_manifestation (ZG_WORLD_ACTIVITY);
    var i = 0;
    foreach (var target in targets.get_keys())
    {
      if (i == 0)
      {
        event_template.add_subject (
          new Subject.full (
            "",
            NFO_AUDIO,
            NFO_MEDIA_STREAM,
            "x-telepathy/call",
            this.tp_identifier.printf (target.get_identifier ()),
            target.get_alias (),
            "net")
        );
      }
      event_template.add_subject (
        new Subject.full (
          this.tp_identifier.printf(target.get_identifier ()),
          NCO_CONTACT,
          NCO_CONTACT_LIST_DATA_OBJECT,
          "",
          this.tp_identifier.printf(target.get_identifier ()),
          target.get_alias (),
          "net")
      );
      i++;
    }
    return event_template;
  }

  private void observe_call_channel (SimpleObserver observer, Account account, 
                                     Connection connection, Channel b_channel,
                                     ChannelDispatchOperation? dispatch_operation,
                                     List<ChannelRequest> requests,
                                     ObserveChannelsContext context)
  {
    CallChannel channel = (CallChannel) b_channel;
   
    channel.state_changed.connect (() => 
      {
        CallFlags flags;
        HashTable<weak void*,weak void*> details;
        TelepathyGLib.CallStateReason reason;
        CallState state = channel.get_state (out flags, out details, out reason);

        var event_template = this.create_call_event (account, channel);
        if (state == 3)
        {
          event_template.set_interpretation (ZG_CREATE_EVENT);
          if (channel.requested == false)
            event_template.set_manifestation (ZG_WORLD_ACTIVITY);
          Timer t = new Timer ();
          t.stop ();
          call_timers.insert (channel.get_object_path (), (owned) t);
          this.push_event (event_template);
        }
        else if ((state == 5 || state ==6) && call_timers.contains (channel.get_object_path ()))
        {
          event_template.set_interpretation (ZG_CREATE_EVENT);
          if (channel.requested == false)
            event_template.set_manifestation (ZG_WORLD_ACTIVITY);
          event_template = this.create_call_event (account, channel);
          if (reason.actor != channel.connection.get_self_handle ())
            event_template.set_manifestation (ZG_WORLD_ACTIVITY);

          if (state == 5)
          {
            event_template.set_interpretation (ZG_ACCESS_EVENT);
            call_timers.lookup (channel.get_object_path ()).start();
            this.push_event (event_template);
          }
          else if (state == 6)
          {
            event_template.set_interpretation (ZG_LEAVE_EVENT);
            if (reason.reason == TelepathyGLib.CallStateChangeReason.REJECTED)
              event_template.set_interpretation (ZG_DENY_EVENT);
            else if (reason.reason == TelepathyGLib.CallStateChangeReason.NO_ANSWER)
              event_template.set_interpretation (ZG_EXPIRE_EVENT);
            var duration  = call_timers.lookup (channel.get_object_path ()).elapsed ();
            call_timers.lookup (channel.get_object_path ()).stop;
            call_timers.remove (channel.get_object_path ());
            //TODO: Add payloads
            var gen = new Generator();
            var root = new Json.Node(NodeType.OBJECT);
            var object = new Json.Object();
            root.set_object(object);
            gen.set_root(root);
            gen.pretty = true;

            var details_obj = new Json.Object ();
            details_obj.set_int_member ("state", state);
            details_obj.set_int_member ("reason", reason.reason);
            details_obj.set_boolean_member ("requested", channel.requested);

            var obj_path = account.get_object_path ();
            obj_path = this.tp_account_path.printf("%s",
                     obj_path [TelepathyGLib.ACCOUNT_OBJECT_PATH_BASE.length:
                     obj_path.length]);

            var targets = "";
            var i = 0;
            foreach (var target in channel.get_members ().get_keys())
            {
              if (i == 0)
                targets = "%s".printf (this.tp_identifier.printf (target.get_identifier ()));
              else 
                targets = "%s; %s".printf (targets,
                     this.tp_identifier.printf (target.get_identifier ()));
              i++;
            }
            if (channel.requested == true)
            {
              details_obj.set_string_member ("host", obj_path);
              details_obj.set_string_member ("recipient", targets);
            }
            else
            {
              details_obj.set_string_member ("host", this.tp_identifier.printf(targets));
              details_obj.set_string_member ("recipient", obj_path);
            }
            details_obj.set_double_member ("duation", duration);
            size_t length;
            object.set_object_member (call_json_domain, details_obj);
            string payload_string = gen.to_data(out length);
            event_template.set_payload (new GLib.ByteArray.take (payload_string.data));
            this.push_event (event_template);
          }
        }
      });
  }

  private void observe_ft_channel (SimpleObserver observer, Account account, 
                                   Connection connection, Channel b_channel,
                                   ChannelDispatchOperation? dispatch_operation,
                                   List<ChannelRequest> requests,
                                   ObserveChannelsContext context)
  {
    FileTransferChannel channel = (FileTransferChannel) b_channel;
    channel.notify["state"].connect (() => {
      if (channel.state == 4 || channel.state == 5)
        {
          var target = channel.get_target_contact ();
          var attr = "%s, %s, %s".printf (FileAttribute.STANDARD_DISPLAY_NAME,
            FileAttribute.STANDARD_CONTENT_TYPE, FileAttribute.STANDARD_SIZE);
          var info = channel.file.query_info (attr, 0, null);
          var obj_path = account.get_object_path ();
          obj_path = this.tp_account_path.printf("%s",
                     obj_path [TelepathyGLib.ACCOUNT_OBJECT_PATH_BASE.length:
                     obj_path.length]);
          var event_template = new Event ();
          if (channel.requested)
          {
            event_template.set_interpretation (ZG_SEND_EVENT);
            event_template.set_manifestation (ZG_USER_ACTIVITY);
          }
          else
          {
            event_template.set_interpretation (ZG_RECEIVE_EVENT);
            event_template.set_manifestation (ZG_WORLD_ACTIVITY);
          }
          event_template.set_actor (this.actor);
          event_template.set_origin (obj_path);
          //============================================//
          var subj = new Subject ();
          subj.set_uri (channel.file.get_uri ());
          subj.set_interpretation (interpretation_for_mimetype (info.get_content_type ()));
          subj.set_manifestation (NFO_FILE_DATA_OBJECT);
          subj.set_text (info.get_display_name ());
          subj.set_mimetype (info.get_content_type ());
          //TODO: create if else
          if (channel.requested == true)
          {
            var split_uri =  channel.file.get_uri ().split ("/");
            var uri = "%s/".printf(string.join ("/", split_uri[0:split_uri.length-1]));
            subj.set_origin (uri);
          }
          else
            subj.set_origin (this.tp_identifier.printf (target.get_identifier ()));
          event_template.add_subject (subj);
          //===========================================//
          event_template.add_subject (
            new Subject.full (this.tp_identifier.printf(target.get_identifier ()),
              NCO_CONTACT,
              NCO_CONTACT_LIST_DATA_OBJECT,
              "",
              this.tp_identifier.printf(target.get_identifier ()),
              target.get_alias (),
              "net"));
          //TODO: Add payloads
          var gen = new Generator();
          var root = new Json.Node(NodeType.OBJECT);
          var object = new Json.Object();
          root.set_object(object);
          gen.set_root(root);
          gen.pretty = true;

          var details_obj = new Json.Object ();
          TelepathyGLib.FileTransferStateChangeReason reason;
          var state = channel.get_state (out reason);
          details_obj.set_int_member ("state", state);
          details_obj.set_int_member ("reason", reason);
          details_obj.set_boolean_member ("requested", channel.requested);
          if (channel.requested == true)
          {
            details_obj.set_string_member ("sender", obj_path);
            details_obj.set_string_member ("recipient", this.tp_identifier.printf(target.get_identifier ()));
          }
          else
          {
            details_obj.set_string_member ("sender", this.tp_identifier.printf(target.get_identifier ()));
            details_obj.set_string_member ("recipient", obj_path);
          }
          details_obj.set_string_member ("mimetype", info.get_content_type ());
          details_obj.set_int_member ("date", channel.get_date ().to_unix ());
          details_obj.set_string_member ("description", channel.get_description ());
          details_obj.set_double_member ("size", (int64)channel.get_size ());
          details_obj.set_string_member ("service", channel.get_service_name ());
          details_obj.set_string_member ("uri", channel.file.get_uri());
          size_t length;
          object.set_object_member (ft_json_domain, details_obj);
          string payload_string = gen.to_data(out length);
          event_template.set_payload (new GLib.ByteArray.take (payload_string.data));
          this.push_event (event_template);
        }
    });
  }

  private void observe_channels (SimpleObserver observer, Account account, 
                                 Connection connection, List<Channel> channels,
                                 ChannelDispatchOperation? dispatch_operation,
                                 List<ChannelRequest> requests,
                                 ObserveChannelsContext context)
  {
    try
    {
      foreach (var channel in channels)
      {
        if (channel is TelepathyGLib.TextChannel)
          this.observe_text_channel (observer, account, connection, channel,
                            dispatch_operation, requests, context);
        else if (channel is TelepathyGLib.CallChannel)
          this.observe_call_channel (observer, account, connection, channel,
                            dispatch_operation, requests, context);
        else if (channel is TelepathyGLib.FileTransferChannel)
          this.observe_ft_channel (observer, account, connection, channel,
                            dispatch_operation, requests, context);
      }
    }
    finally
    {
      context.accept ();
    }
  }

  public override void start ()
  {
    observer = new TelepathyGLib.SimpleObserver.with_factory (factory,
                                                              true,
                                                              "Zeitgeist",
                                                              false,
                                                              observe_channels);

    // Add Call Channel Filters
    HashTable<string,Value?> call_filter = new HashTable<string,Value?> (str_hash, str_equal);
    call_filter.insert (TelepathyGLib.PROP_CHANNEL_CHANNEL_TYPE,
                   TelepathyGLib.IFACE_CHANNEL_TYPE_CALL);
    call_filter.insert (TelepathyGLib.PROP_CHANNEL_TARGET_HANDLE_TYPE, 1);
    observer.add_observer_filter (call_filter);

    // Add Text Channel Filters
    HashTable<string,Value?> text_filter = new HashTable<string,Value?> (str_hash, str_equal);
    text_filter.insert (TelepathyGLib.PROP_CHANNEL_CHANNEL_TYPE,
                   TelepathyGLib.IFACE_CHANNEL_TYPE_TEXT);
    text_filter.insert (TelepathyGLib.PROP_CHANNEL_TARGET_HANDLE_TYPE, 1);
    observer.add_observer_filter (text_filter);

    // Add FileTransfer Channel Filters
    HashTable<string,Value?> ft_filter = new HashTable<string,Value?> (str_hash, str_equal);
    ft_filter.insert (TelepathyGLib.PROP_CHANNEL_CHANNEL_TYPE,
                   TelepathyGLib.IFACE_CHANNEL_TYPE_FILE_TRANSFER);
    ft_filter.insert (TelepathyGLib.PROP_CHANNEL_TARGET_HANDLE_TYPE, 1);
    observer.add_observer_filter (ft_filter);

    observer.register ();
  }

  public override void stop ()
  {
    observer.unregister ();
  }
}
