------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                         Copyright (C) 2003-2004                          --
--                                ACT-Europe                                --
--                                                                          --
--  Authors: Dmitriy Anisimkov - Pascal Obry                                --
--                                                                          --
--  This library is free software; you can redistribute it and/or modify    --
--  it under the terms of the GNU General Public License as published by    --
--  the Free Software Foundation; either version 2 of the License, or (at   --
--  your option) any later version.                                         --
--                                                                          --
--  This library is distributed in the hope that it will be useful, but     --
--  WITHOUT ANY WARRANTY; without even the implied warranty of              --
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU       --
--  General Public License for more details.                                --
--                                                                          --
--  You should have received a copy of the GNU General Public License       --
--  along with this library; if not, write to the Free Software Foundation, --
--  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.          --
--                                                                          --
--  As a special exception, if other files instantiate generics from this   --
--  unit, or you link this unit with other files to produce an executable,  --
--  this  unit  does not  by itself cause  the resulting executable to be   --
--  covered by the GNU General Public License. This exception does not      --
--  however invalidate any other reasons why the executable file  might be  --
--  covered by the  GNU Public License.                                     --
------------------------------------------------------------------------------

--  $Id$

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AWS.Config;
with AWS.MIME;
with AWS.OS_Lib;
with AWS.Parameters;
with AWS.POP;
with AWS.Resources.Streams;
with AWS.Services.Transient_Pages;
with AWS.Session;
with AWS.SMTP.Client;
with AWS.Templates;
with AWS.Messages;
with AWS.Utils;

package body AWS.Services.Web_Mail is

   use Ada;
   use Ada.Strings.Unbounded;

   use AWS;

   function Login (Request : in Status.Data) return Response.Data;
   --  Get the login data from Request and returns the summary of the mailbox

   function Summary (Request : in AWS.Status.Data) return AWS.Response.Data;
   --  Returns a list of all messages in the mailbox

   function Message (Request : in AWS.Status.Data) return AWS.Response.Data;
   --  Returns a list of all messages in the mailbox

   function Delete (Request : in AWS.Status.Data) return AWS.Response.Data;
   --  Delete a message, returns to the summary page

   function Reply (Request : in AWS.Status.Data) return AWS.Response.Data;
   --  Returns a reply form

   function Send (Request : in AWS.Status.Data) return AWS.Response.Data;
   --  Send a message, used by the reply form above

   --------------
   -- Callback --
   --------------

   function Callback (Request : in AWS.Status.Data) return AWS.Response.Data is
      WWW_Root   : String renames AWS.Config.WWW_Root (Config.Get_Current);
      WM_Session : constant Session.ID := Status.Session (Request);
      URI        : constant String     := Status.URI (Request);

      procedure Check_Session;
      --  Checks current session data and set corresponding variables,
      --  POP_Server is set to Null_Unbounded_String if no session data found.

      SMTP_Server : Unbounded_String;
      POP_Server  : Unbounded_String;
      User_Name   : Unbounded_String;
      Password    : Unbounded_String;

      -------------------
      -- Check_Session --
      -------------------

      procedure Check_Session is
      begin
         if Session.Exist (WM_Session, "WM_POP_SERVER") then
            SMTP_Server := To_Unbounded_String
              (String'(Session.Get (WM_Session, "WM_SMTP_SERVER")));
            POP_Server := To_Unbounded_String
              (String'(Session.Get (WM_Session, "WM_POP_SERVER")));
            User_Name := To_Unbounded_String
              (String'(Session.Get (WM_Session, "WM_USER_NAME")));
            Password := To_Unbounded_String
              (String'(Session.Get (WM_Session, "WM_PASSWORD")));
         end if;
      end Check_Session;

   begin
      Check_Session;

      if URI = "/wm_login" then
         return Login (Request);

      elsif URI = "/" or else POP_Server = Null_Unbounded_String then
         return Response.File (MIME.Text_HTML, WWW_Root & "/wm_login.html");

      elsif URI = "/wm_summary" then
         return Summary (Request);

      elsif URI = "/wm_message" then
         return Message (Request);

      elsif URI = "/wm_reply" then
         return Reply (Request);

      elsif URI = "/wm_delete" then
         return Delete (Request);

      elsif URI = "/wm_send" then
         return Send (Request);

      else
         --  Check for a transient resource

         declare
            use type Resources.Streams.Stream_Access;

            Stream : constant AWS.Resources.Streams.Stream_Access
              := Services.Transient_Pages.Get (URI);
         begin
            if Stream /= null then
               return Response.Stream
                 (Status.Content_Type (Request),
                  Stream,
                  Server_Close => False);

            else
               --  This is not a known resource

               if OS_Lib.Is_Regular_File (WWW_Root & "404.thtml") then

                  declare
                     Table : constant AWS.Templates.Translate_Table
                       := (1 => Templates.Assoc ("PAGE", URI));
                  begin
                     --  Here we return the 404.thtml page if found. Note that
                     --  on Microsoft IE this page will be displayed only if
                     --  the total page size is bigger than 512 bytes or if it
                     --  includes at leat one image.

                     return Response.Acknowledge
                       (Messages.S404,
                        Templates.Parse (WWW_Root & "404.thtml", Table));
                  end;

               else
                  return Response.Acknowledge
                    (Messages.S404,
                     "<p>Page '" & URI & "' Not found.");
               end if;
            end if;
         end;
      end if;
   end Callback;

   ------------
   -- Delete --
   ------------

   function Delete (Request : in AWS.Status.Data) return AWS.Response.Data is
      WM_Session : constant Session.ID := Status.Session (Request);
      P_List     : constant Parameters.List := Status.Parameters (Request);

      POP_Server : constant String
        := Session.Get (WM_Session, "WM_POP_SERVER");

      User_Name  : constant String
        := Session.Get (WM_Session, "WM_USER_NAME");

      Password   : constant String
        := Session.Get (WM_Session, "WM_PASSWORD");

      No_Message : constant Positive
        := Positive'Value (Parameters.Get (P_List, "NO_MESSAGE"));

      Mailbox : POP.Mailbox;
   begin
      Mailbox := POP.Initialize (POP_Server, User_Name, Password);

      POP.Delete (Mailbox, No_Message);

      POP.Close (Mailbox);

      return Response.URL ("/wm_summary");
   end Delete;

   -----------
   -- Login --
   -----------

   function Login (Request : in Status.Data) return Response.Data is
      WM_Session : constant Session.ID      := Status.Session (Request);
      P_List     : constant Parameters.List := Status.Parameters (Request);
   begin
      Session.Set (WM_Session, "WM_SMTP_SERVER",
                   Parameters.Get (P_List, "WM_SMTP_SERVER"));
      Session.Set (WM_Session, "WM_POP_SERVER",
                   Parameters.Get (P_List, "WM_POP_SERVER"));
      Session.Set (WM_Session, "WM_USER_NAME",
                   Parameters.Get (P_List, "WM_USER_NAME"));
      Session.Set (WM_Session, "WM_PASSWORD",
                   Parameters.Get (P_List, "WM_PASSWORD"));
      return Response.URL ("/wm_summary");
   end Login;

   -------------
   -- Message --
   -------------

   function Message (Request : in AWS.Status.Data) return AWS.Response.Data is
      use type Templates.Translate_Table;

      WWW_Root   : String renames Config.WWW_Root (Config.Get_Current);
      WM_Session : constant Session.ID := Status.Session (Request);
      P_List     : constant Parameters.List := Status.Parameters (Request);

      POP_Server : constant String
        := Session.Get (WM_Session, "WM_POP_SERVER");

      User_Name  : constant String
        := Session.Get (WM_Session, "WM_USER_NAME");

      Password   : constant String
        := Session.Get (WM_Session, "WM_PASSWORD");

      No_Message : constant Positive
        := Positive'Value (Parameters.Get (P_List, "NO_MESSAGE"));

      Mailbox : POP.Mailbox;
      Mess    : POP.Message;

      function Get_Content return Templates.Translate_Table;
      --  Returns content and attachments

      -----------------
      -- Get_Content --
      -----------------

      function Get_Content return Templates.Translate_Table is

         Content  : Unbounded_String;
         Att_Name : Templates.Vector_Tag;
         Att_Ref  : Templates.Vector_Tag;

         procedure Add_Attachment
           (Attachment : in     POP.Attachment;
            Index      : in     Positive;
            Quit       : in out Boolean);
         --  Add new attachment data

         --------------------
         -- Add_Attachment --
         --------------------

         procedure Add_Attachment
           (Attachment : in     POP.Attachment;
            Index      : in     Positive;
            Quit       : in out Boolean)
         is
            pragma Unreferenced (Index, Quit);

            use type Templates.Vector_Tag;
         begin
            if POP.Is_File (Attachment) then
               declare
                  Filename : constant String := POP.Filename (Attachment);
                  URI      : constant String
                    := Services.Transient_Pages.Get_URI & "/" & Filename;
                  --  We add the filename after the uniq URI to tell the
                  --  browser to use this name to save the file on disk.
               begin
                  --  Add a reference to the attachment into the message body

                  Append (Content, ASCII.CR & ASCII.LF);
                  Append (Content, "<" & Filename & ">");

                  --  Add attachment data

                  Att_Name := Att_Name & Filename;
                  Att_Ref  := Att_Ref & URI;

                  Services.Transient_Pages.Register
                    (URI,
                     POP.Content (Attachment),
                     Lifetime => 120.0);
               end;

            else
               Append (Content, ASCII.CR & ASCII.LF);
               Append (Content, Unbounded_String'(POP.Content (Attachment)));
            end if;
         end Add_Attachment;

         ---------------------------
         -- Add_Every_Attachments --
         ---------------------------

         procedure Add_Every_Attachment is
            new POP.For_Every_Attachment (Add_Attachment);

      begin
         --  Add the message content

         Content := POP.Content (Mess);

         --  Analyse all attachments

         Add_Every_Attachment (Mess);

         --  Returns the corresponding translate table

         return Templates.Translate_Table'
           (Templates.Assoc ("WM_CONTENT", Content),
            Templates.Assoc ("WM_ATT_NAME_V", Att_Name),
            Templates.Assoc ("WM_ATT_REF_V", Att_Ref));
      end Get_Content;

   begin
      Mailbox := POP.Initialize (POP_Server, User_Name, Password);

      Mess := POP.Get (Mailbox, No_Message);

      POP.Close (Mailbox);

      return Response.Build
        (MIME.Text_HTML,
         Unbounded_String'
           (Templates.Parse
              (WWW_Root & "/wm_message.thtml",
               Templates.Translate_Table'
                 (Templates.Assoc ("AWS_VERSION", AWS.Version),
                  Templates.Assoc ("WM_USER_NAME", User_Name),
                  Templates.Assoc ("WM_POP_SERVER", POP_Server),
                  Templates.Assoc
                    ("WM_MESS_COUNT", POP.Message_Count (Mailbox)),
                  Templates.Assoc ("WM_MESSAGE", No_Message),
                  Templates.Assoc ("WM_SUBJECT", POP.Subject (Mess)),
                  Templates.Assoc ("WM_DATE", POP.Date (Mess)),
                  Templates.Assoc ("WM_FROM", POP.From (Mess)),
                  Templates.Assoc ("WM_CC", POP.CC (Mess)))
               & Get_Content)));
   end Message;

   -----------
   -- Reply --
   -----------

   function Reply (Request : in AWS.Status.Data) return AWS.Response.Data is
      use type Templates.Translate_Table;

      WWW_Root   : String renames Config.WWW_Root (Config.Get_Current);
      WM_Session : constant Session.ID := Status.Session (Request);
      P_List     : constant Parameters.List := Status.Parameters (Request);

      SMTP_Server : constant String
        := Session.Get (WM_Session, "WM_SMTP_SERVER");

      POP_Server : constant String
        := Session.Get (WM_Session, "WM_POP_SERVER");

      User_Name  : constant String
        := Session.Get (WM_Session, "WM_USER_NAME");

      Password   : constant String
        := Session.Get (WM_Session, "WM_PASSWORD");

      No_Message : constant Positive
        := Positive'Value (Parameters.Get (P_List, "NO_MESSAGE"));

      Mailbox : POP.Mailbox;
      Mess    : POP.Message;

      function Get_Content return Templates.Translate_Table;
      --  Returns content, all lines being prefixed

      -----------------
      -- Get_Content --
      -----------------

      function Get_Content return Templates.Translate_Table is
         Prefix  : constant String := "> ";
         Content : Unbounded_String;
         K       : Positive := Prefix'Length + 1;
      begin
         --  Get message content

         Content := POP.Content (Mess);

         --  Prefix first line with "> "

         Content := Prefix & Content;

         --  Prefix every lines with "> "

         while K < Length (Content) loop
            if Element (Content, K) = ASCII.LF then
               Insert (Content, K + 1, Prefix);
            end if;
            K := K + 1;
         end loop;

         return Templates.Translate_Table'
           (1 => Templates.Assoc ("WM_CONTENT", Content));
      end Get_Content;

   begin
      Mailbox := POP.Initialize (POP_Server, User_Name, Password);

      Mess := POP.Get (Mailbox, No_Message);

      POP.Close (Mailbox);

      return Response.Build
        (MIME.Text_HTML,
         Unbounded_String'
           (Templates.Parse
              (WWW_Root & "/wm_reply.thtml",
               Templates.Translate_Table'
                 (Templates.Assoc ("AWS_VERSION", AWS.Version),
                  Templates.Assoc ("WM_USER_NAME", User_Name),
                  Templates.Assoc ("WM_SMTP_SERVER", SMTP_Server),
                  Templates.Assoc ("WM_POP_SERVER", POP_Server),
                  Templates.Assoc
                    ("WM_MESS_COUNT", POP.Message_Count (Mailbox)),
                  Templates.Assoc ("WM_MESSAGE", No_Message),
                  Templates.Assoc ("WM_SUBJECT", POP.Subject (Mess)),
                  Templates.Assoc ("WM_DATE", POP.Date (Mess)),
                  Templates.Assoc ("WM_FROM", POP.From (Mess)),
                  Templates.Assoc ("WM_CC", POP.CC (Mess)))
               & Get_Content)));
   end Reply;

   ----------
   -- Send --
   ----------

   function Send (Request : in AWS.Status.Data) return AWS.Response.Data is
      WWW_Root   : String renames Config.WWW_Root (Config.Get_Current);
      WM_Session : constant Session.ID := Status.Session (Request);
      P_List     : constant Parameters.List := Status.Parameters (Request);

      POP_Server : constant String
        := Session.Get (WM_Session, "WM_POP_SERVER");

      SMTP_Server : constant String
        := Session.Get (WM_Session, "WM_SMTP_SERVER");

      User_Name  : constant String
        := Session.Get (WM_Session, "WM_USER_NAME");

      function Get_From return SMTP.E_Mail_Data;
      --  Build the From e-mail

      --------------
      -- Get_From --
      --------------

      function Get_From return SMTP.E_Mail_Data is
         K      : constant Natural := Strings.Fixed.Index (POP_Server, ".");
         E_Mail : Unbounded_String;
      begin
         if K = 0 then
            --  No domain specified, this is a local machine
            E_Mail := To_Unbounded_String (User_Name & '@' & POP_Server);
         else
            --  Get the domain name after the first dot
            E_Mail := To_Unbounded_String
              (User_Name & '@' & POP_Server (K + 1 .. POP_Server'Last));
         end if;

         return SMTP.E_Mail (To_String (E_Mail), To_String (E_Mail));
      end Get_From;

      WM_SMTP     : SMTP.Receiver;
      Result      : SMTP.Status;
   begin
      WM_SMTP := SMTP.Client.Initialize (SMTP_Server);

      SMTP.Client.Send
        (WM_SMTP,
         From    => Get_From,
         To      => SMTP.Parse (Parameters.Get (P_List, "WM_TO")),
         Subject => Parameters.Get (P_List, "WM_SUBJECT"),
         Message => Parameters.Get (P_List, "WM_CONTENT"),
         Status  => Result);

      if SMTP.Is_Ok (Result) then
         return Response.URL ("/wm_summary");
      else
         return Response.Build
           (MIME.Text_HTML,
            String'
              (Templates.Parse
                 (WWW_Root & "/wm_error.thtml",
                  Templates.Translate_Table'
                    (1 => Templates.Assoc
                       ("ERROR_MESSAGE", SMTP.Status_Message (Result))))));
      end if;

   exception
      when Constraint_Error =>
         return Response.Build
           (MIME.Text_HTML,
            String'
              (Templates.Parse
                 (WWW_Root & "/wm_error.thtml",
                  Templates.Translate_Table'
                    (1 => Templates.Assoc
                       ("ERROR_MESSAGE", "Can't parse e-mail")))));
   end Send;

   -------------
   -- Summary --
   -------------

   function Summary (Request : in AWS.Status.Data) return AWS.Response.Data is
      WWW_Root   : String renames Config.WWW_Root (Config.Get_Current);
      WM_Session : constant Session.ID := Status.Session (Request);

      POP_Server : constant String
        := Session.Get (WM_Session, "WM_POP_SERVER");

      User_Name  : constant String
        := Session.Get (WM_Session, "WM_USER_NAME");

      Password   : constant String
        := Session.Get (WM_Session, "WM_PASSWORD");

      procedure Add_Message
        (Message : in     POP.Message;
         Index   : in     Positive;
         Quit    : in out Boolean);
      --  Add message information into the vertor tags

      Index_V   : Templates.Vector_Tag;
      Size_V    : Templates.Vector_Tag;
      Date_V    : Templates.Vector_Tag;
      From_V    : Templates.Vector_Tag;
      Subject_V : Templates.Vector_Tag;

      -----------------
      -- Add_Message --
      -----------------

      procedure Add_Message
        (Message : in     POP.Message;
         Index   : in     Positive;
         Quit    : in out Boolean)
      is
         pragma Unreferenced (Quit);
         use type Templates.Vector_Tag;
      begin
         Index_V   := Utils.Image (Index)   & Index_V;
         Size_V    := POP.Size (Message)    & Size_V;
         Date_V    := POP.Date (Message)    & Date_V;
         From_V    := POP.From (Message)    & From_V;
         Subject_V := POP.Subject (Message) & Subject_V;
      end Add_Message;

      -------------------------
      -- Add_Message_Headers --
      -------------------------

      procedure Add_Message_Headers is
         new POP.For_Every_Message_Header (Add_Message);

      Mailbox : POP.Mailbox;

   begin
      Mailbox := POP.Initialize (POP_Server, User_Name, Password);

      Add_Message_Headers (Mailbox);

      POP.Close (Mailbox);

      return Response.Build
        (MIME.Text_HTML,
         Unbounded_String'
           (Templates.Parse
              (WWW_Root & "/wm_summary.thtml",
               Templates.Translate_Table'
                 (Templates.Assoc ("AWS_VERSION", AWS.Version),
                  Templates.Assoc
                    ("WM_MESS_COUNT", POP.Message_Count (Mailbox)),
                  Templates.Assoc ("WM_MAILBOX_SIZE", POP.Size (Mailbox)),
                  Templates.Assoc ("WM_MESSAGE_V", Index_V),
                  Templates.Assoc ("WM_SIZE_V", Size_V),
                  Templates.Assoc ("WM_FROM_V", From_V),
                  Templates.Assoc ("WM_DATE_V", Date_V),
                  Templates.Assoc ("WM_SUBJECT_V", Subject_V),
                  Templates.Assoc ("WM_USER_NAME", User_Name),
                  Templates.Assoc ("WM_POP_SERVER", POP_Server)))));
   end Summary;

end AWS.Services.Web_Mail;
