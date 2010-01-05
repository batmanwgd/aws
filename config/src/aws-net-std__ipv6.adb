------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                     Copyright (C) 2004-2009, AdaCore                     --
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

with Ada.Unchecked_Deallocation;

with AWS.Net.Log;
with AWS.OS_Lib;
with AWS.Utils;

with Interfaces.C.Strings;
with System.Address_To_Access_Conversions;

package body AWS.Net.Std is

   use Interfaces;

   No_Socket : constant C.int := C.int (-1);
   Failure   : constant C.int := C.int (-1);

   type Socket_Hidden is record
      FD : Interfaces.C.int := No_Socket;
   end record;

   type In6_Addr is array (1 .. 8) of Interfaces.Unsigned_16;
   pragma Convention (C, In6_Addr);

   type Sockaddr_In6 is record
      Family    : Interfaces.C.short;          -- AF_INET6
      Port      : Interfaces.C.unsigned_short; -- transport layer port #
      FlowInfo  : Interfaces.C.unsigned_long;  -- IPv6 traffic class&flow info
      Addr      : In6_Addr;                    -- IPv6 address
      Scope_Id  : Interfaces.C.unsigned_long;  -- set of interfaces for a scope
   end record;
   pragma Convention (C, Sockaddr_In6);

   package AC6 is new System.Address_To_Access_Conversions (Sockaddr_In6);

   procedure Raise_Socket_Error (Error : Integer);
   pragma No_Return (Raise_Socket_Error);
   pragma Inline (Raise_Socket_Error);

   procedure Raise_Socket_Error (Error : Integer; Socket : Socket_Type);
   pragma No_Return (Raise_Socket_Error);
   pragma Inline (Raise_Socket_Error);

   procedure Raise_Socket_Error (Errmsg : String);
   pragma No_Return (Raise_Socket_Error);
   pragma Inline (Raise_Socket_Error);
   --  Log socket error and raise exception

   function Image (Sin6 : Sockaddr_In6; Len : OS_Lib.socklen_t) return String;
   --  Returns image of the socket address

   function Get_Addr_Info
     (Host  : String;
      Port  : Natural;
      Flags : Interfaces.C.int := 0) return OS_Lib.Addr_Info_Access;
   --  Returns the inet address information for the given host and port.
   --  Flags should be used from getaddrinfo C routine.

   function Get_Int_Sock_Opt
     (Socket : Socket_Type; Name : Interfaces.C.int) return Integer;
   --  Return socket option with Integer size

   procedure Set_Int_Sock_Opt
     (Socket : Socket_Type;
      Name   : Interfaces.C.int;
      Value  : Integer;
      Level  : Interfaces.C.int := OS_Lib.SOL_SOCKET);
   --  Return socket option with Integer size

   procedure Set_Non_Blocking_Mode (Socket : Socket_Type);
   --  Set the socket to the non-blocking mode.
   --  AWS is not using blocking sockets internally.

   function Swap_Little_Endian
     (S : Interfaces.Unsigned_16) return Interfaces.Unsigned_16;

   function C_Socket (Domain, Typ, Protocol : C.int) return C.int;
   pragma Import (Stdcall, C_Socket, "socket");

   function C_Getsockname
     (S       : C.int;
      Name    : System.Address;
      Namelen : not null access OS_Lib.socklen_t) return C.int;
   pragma Import (Stdcall, C_Getsockname, "getsockname");

   function C_Getsockopt
     (S       : C.int;
      Level   : C.int;
      OptName : C.int;
      OptVal  : System.Address;
      OptLen  : not null access C.int) return C.int;
   pragma Import (Stdcall, C_Getsockopt, "getsockopt");

   function C_Getpeername
     (S       : C.int;
      Name    : System.Address;
      Namelen : not null access OS_Lib.socklen_t) return C.int;
   pragma Import (Stdcall, C_Getpeername, "getpeername");

   function C_Gethostname
     (Name : System.Address; Namelen : C.int) return C.int;
   pragma Import (Stdcall, C_Gethostname, "gethostname");

   -------------------
   -- Accept_Socket --
   -------------------

   overriding procedure Accept_Socket
     (Socket     : Net.Socket_Type'Class;
      New_Socket : in out Socket_Type)
   is
      use type C.int;

      function C_Accept
        (S       : Integer;
         Addr    : System.Address;
         Addrlen : not null access C.int) return C.int;
      pragma Import (Stdcall, C_Accept, "accept");

      Dummy : String (1 .. 32);
      Len   : aliased C.int := Dummy'Length;

   begin
      if New_Socket.S /= null then
         New_Socket := Socket_Type'(Net.Socket_Type with others => <>);
      end if;

      New_Socket.S := new Socket_Hidden;

      Wait_For (Input, Socket);

      New_Socket.S.FD := C_Accept (Get_FD (Socket), Dummy'Address, Len'Access);

      if New_Socket.S.FD = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket_Type (Socket));
      end if;

      if Net.Log.Is_Event_Active then
         Net.Log.Event (Net.Log.Accept_Socket, New_Socket);
      end if;

      Set_Non_Blocking_Mode (New_Socket);
   end Accept_Socket;

   ----------
   -- Bind --
   ----------

   overriding procedure Bind
     (Socket        : in out Socket_Type;
      Port          : Natural;
      Host          : String  := "";
      Reuse_Address : Boolean := False)
   is
      use type C.int;

      Info  : constant OS_Lib.Addr_Info_Access :=
                Get_Addr_Info (Host, Port, OS_Lib.AI_PASSIVE);
      FD    : C.int;
      Res   : C.int;
      Errno : Integer;

      function C_Bind
        (S       : C.int;
         Name    : System.Address;
         Namelen : C.int) return C.int;
      pragma Import (Stdcall, C_Bind, "bind");

   begin
      if Socket.S /= null then
         Socket := Socket_Type'(Net.Socket_Type with others => <>);
      end if;

      FD := C_Socket (Info.ai_family, Info.ai_socktype, Info.ai_protocol);

      if FD = Failure then
         OS_Lib.FreeAddrInfo (Info);
         Raise_Socket_Error (OS_Lib.Socket_Errno);
      end if;

      Socket.S := new Socket_Hidden'(FD => FD);

      if Reuse_Address then
         Set_Int_Sock_Opt (Socket, OS_Lib.SO_REUSEADDR, 1);
      end if;

      Res := C_Bind (FD, Info.ai_addr, C.int (Info.ai_addrlen));

      OS_Lib.FreeAddrInfo (Info);

      if Res = Failure then
         Errno := OS_Lib.Socket_Errno;
         Res   := OS_Lib.C_Close (FD);
         Raise_Socket_Error (Errno, Socket);
      end if;

      Set_Non_Blocking_Mode (Socket);
   end Bind;

   -------------
   -- Connect --
   -------------

   overriding procedure Connect
     (Socket : in out Socket_Type;
      Host   : String;
      Port   : Positive;
      Wait   : Boolean := True)
   is
      use type C.int;

      Info  : constant OS_Lib.Addr_Info_Access := Get_Addr_Info (Host, Port);
      FD    : C.int;
      Res   : C.int;
      Errno : Integer;

      function C_Connect
        (S       : C.int;
         Name    : System.Address;
         Namelen : C.int) return C.int;
      pragma Import (Stdcall, C_Connect, "connect");

   begin
      if Socket.S /= null then
         Socket := Socket_Type'(Net.Socket_Type with others => <>);
      end if;

      FD := C_Socket (Info.ai_family, Info.ai_socktype, Info.ai_protocol);

      if FD = Failure then
         OS_Lib.FreeAddrInfo (Info);
         Raise_Socket_Error (OS_Lib.Socket_Errno);
      end if;

      Socket.S := new Socket_Hidden'(FD => FD);

      Set_Non_Blocking_Mode (Socket);

      Res := C_Connect (FD, Info.ai_addr, C.int (Info.ai_addrlen));

      if Res = Failure then
         Errno := OS_Lib.Socket_Errno;

         if Errno = OS_Lib.EWOULDBLOCK
           or else Errno = OS_Lib.EINPROGRESS
         then
            Errno := 0;

            if Wait then
               declare
                  Events : constant Event_Set
                    := Net.Wait (Socket, (Output => True, Input => False));
               begin
                  if Events (Error) then
                     Errno := Std.Errno (Socket);
                  elsif not Events (Output) then
                     Errno := OS_Lib.ETIMEDOUT;
                  end if;
               end;
            end if;
         end if;

         if Errno /= 0 then
            Res := OS_Lib.C_Close (FD);

            declare
               Addr : constant String :=
                 Image (AC6.To_Pointer (Info.ai_addr).all, Info.ai_addrlen);
            begin
               OS_Lib.FreeAddrInfo (Info);
               Raise_Socket_Error (Socket, Error_Message (Errno) & ' ' & Addr);
            end;
         end if;
      end if;

      OS_Lib.FreeAddrInfo (Info);

      if Net.Log.Is_Event_Active then
         Net.Log.Event (Net.Log.Connect, Socket);
      end if;
   end Connect;

   -----------
   -- Errno --
   -----------

   overriding function Errno (Socket : Socket_Type) return Integer is
   begin
      return Get_Int_Sock_Opt (Socket, OS_Lib.SO_ERROR);
   end Errno;

   ----------
   -- Free --
   ----------

   overriding procedure Free (Socket : in out Socket_Type) is
      procedure Free is
         new Ada.Unchecked_Deallocation (Socket_Hidden, Socket_Hidden_Access);
   begin
      Free (Socket.S);
   end Free;

   --------------
   -- Get_Addr --
   --------------

   overriding function Get_Addr (Socket : Socket_Type) return String is
      use type C.int;
      use type OS_Lib.socklen_t;

      Name : aliased Sockaddr_In6;
      Len  : aliased OS_Lib.socklen_t := Name'Size / 8;

   begin
      if C_Getsockname (Socket.S.FD, Name'Address, Len'Access) = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;

      return Image (Name, Len);
   end Get_Addr;

   -------------------
   -- Get_Addr_Info --
   -------------------

   function Get_Addr_Info
     (Host  : String;
      Port  : Natural;
      Flags : Interfaces.C.int := 0) return OS_Lib.Addr_Info_Access
   is
      package CS renames Interfaces.C.Strings;
      use type C.int;
      use type OS_Lib.Addr_Info_Access;

      C_Node : aliased C.char_array := C.To_C (Host);
      P_Node : CS.chars_ptr;
      C_Serv : aliased C.char_array := C.To_C (AWS.Utils.Image (Port));
      Res    : C.int;
      Result : aliased OS_Lib.Addr_Info_Access;
      Hints  : constant OS_Lib.Addr_Info :=
                 (ai_family    => OS_Lib.PF_UNSPEC,
                  ai_socktype  => OS_Lib.SOCK_STREAM,
                  ai_protocol  => OS_Lib.IPPROTO_IP,
                  ai_flags     => Flags,
                  ai_addrlen   => 0,
                  ai_canonname => CS.Null_Ptr,
                  ai_addr      => System.Null_Address,
                  ai_next      => null);
   begin
      if Host = "" then
         P_Node := CS.Null_Ptr;
      else
         P_Node := CS.To_Chars_Ptr (C_Node'Unchecked_Access);
      end if;

      Res := OS_Lib.GetAddrInfo
               (node    => P_Node,
                service => CS.To_Chars_Ptr (C_Serv'Unchecked_Access),
                hints   => Hints,
                res     => Result'Access);

      if Res = OS_Lib.EAI_SYSTEM then
         Raise_Socket_Error (OS_Lib.Socket_Errno);

      elsif Res /= 0 then
         Raise_Socket_Error (CS.Value (OS_Lib.GAI_StrError (Res)));
      end if;

      return Result;
   end Get_Addr_Info;

   ------------
   -- Get_FD --
   ------------

   overriding function Get_FD (Socket : Socket_Type) return Integer is
   begin
      if Socket.S = null then
         return Integer (No_Socket);
      else
         return Integer (Socket.S.FD);
      end if;
   end Get_FD;

   ----------------------
   -- Get_Int_Sock_Opt --
   ----------------------

   function Get_Int_Sock_Opt
     (Socket : Socket_Type; Name : Interfaces.C.int) return Integer
   is
      use type C.int;

      Res : aliased C.int := 0;
      Len : aliased C.int := Res'Size / System.Storage_Unit;

      RC  : constant C.int :=
              C_Getsockopt
                (S       => Socket.S.FD,
                 Level   => OS_Lib.SOL_SOCKET,
                 OptName => Name,
                 OptVal  => Res'Address,
                 OptLen  => Len'Access);
   begin
      if RC = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;

      return Integer (Res);
   end Get_Int_Sock_Opt;

   --------------
   -- Get_Port --
   --------------

   overriding function Get_Port (Socket : Socket_Type) return Positive is
      use type C.int;
      use type OS_Lib.socklen_t;

      Name : aliased Sockaddr_In6;
      Len  : aliased OS_Lib.socklen_t := Name'Size / 8;

   begin
      if C_Getsockname (Socket.S.FD, Name'Address, Len'Access) = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;

      return Positive
               (Swap_Little_Endian (Interfaces.Unsigned_16 (Name.Port)));
   end Get_Port;

   -----------------------------
   -- Get_Receive_Buffer_Size --
   -----------------------------

   overriding function Get_Receive_Buffer_Size
     (Socket : Socket_Type) return Natural is
   begin
      return Get_Int_Sock_Opt (Socket, OS_Lib.SO_RCVBUF);
   end Get_Receive_Buffer_Size;

   --------------------------
   -- Get_Send_Buffer_Size --
   --------------------------

   overriding function Get_Send_Buffer_Size
     (Socket : Socket_Type) return Natural is
   begin
      return Get_Int_Sock_Opt (Socket, OS_Lib.SO_SNDBUF);
   end Get_Send_Buffer_Size;

   ---------------
   -- Host_Name --
   ---------------

   function Host_Name return String is
      use type C.int;
      Name : aliased C.char_array (1 .. 64);
   begin
      if C_Gethostname (Name'Address, Name'Length) = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno);
      end if;

      return C.To_Ada (Name);
   end Host_Name;

   -----------
   -- Image --
   -----------

   function Image
     (Sin6 : Sockaddr_In6; Len : OS_Lib.socklen_t) return String
   is
      use type C.int;
      package CS renames Interfaces.C.Strings;

      function getnameinfo
        (sa      : System.Address;
         salen   : OS_Lib.socklen_t;
         host    : CS.chars_ptr;
         hostlen : C.size_t;
         serv    : CS.chars_ptr;
         servlen : C.size_t;
         flags   : C.int) return C.int;
      pragma Import (StdCall, getnameinfo, "getnameinfo");

      Host : aliased C.char_array := (0 .. 128 => C.nul);
      Res  : constant C.int :=
               getnameinfo
                 (sa      => Sin6'Address,
                  salen   => Len,
                  host    => CS.To_Chars_Ptr (Host'Unchecked_Access),
                  hostlen => Host'Length,
                  serv    => CS.Null_Ptr,
                  servlen => 0,
                  flags   => OS_Lib.NI_NUMERICHOST);
   begin
      if Res = OS_Lib.EAI_SYSTEM then
         Raise_Socket_Error (OS_Lib.Socket_Errno);

      elsif Res /= 0 then
         Raise_Socket_Error (CS.Value (OS_Lib.GAI_StrError (Res)));
      end if;

      declare
         Result      : constant String := C.To_Ada (Host);
         IPv4_Prefix : constant String := "::ffff:";
      begin
         --  Looks like it is not neccessary in OpenSUSE 11.2, but is necessary
         --  in OpenSUSE 11.0. So we can remove it, after all the linux runtime
         --  libraries will remove this prefix anyway.

         if Result'Length > IPv4_Prefix'Length
           and then Result (IPv4_Prefix'Range) = IPv4_Prefix
         then
            return Result (IPv4_Prefix'Last + 1 .. Result'Last);
         else
            return Result;
         end if;
      end;
   end Image;

   ------------
   -- Listen --
   ------------

   overriding procedure Listen
     (Socket : Socket_Type; Queue_Size : Positive := 5)
   is
      use type C.int;

      function C_Listen (S : C.int; Backlog : C.int) return C.int;
      pragma Import (Stdcall, C_Listen, "listen");

   begin
      if C_Listen (Socket.S.FD, C.int (Queue_Size)) = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;
   end Listen;

   ---------------
   -- Peer_Addr --
   ---------------

   overriding function Peer_Addr (Socket : Socket_Type) return String is
      use type C.int;
      use type OS_Lib.socklen_t;

      Sin6 : aliased Sockaddr_In6;
      Len  : aliased OS_Lib.socklen_t := Sin6'Size / 8;

   begin
      if C_Getpeername (Socket.S.FD, Sin6'Address, Len'Access) = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;

      return Image (Sin6, Len);

   end Peer_Addr;

   ---------------
   -- Peer_Port --
   ---------------

   overriding function Peer_Port (Socket : Socket_Type) return Positive is
      use type C.int;
      use type OS_Lib.socklen_t;

      Name : aliased Sockaddr_In6;
      Len  : aliased OS_Lib.socklen_t := Name'Size / 8;

   begin
      if C_Getpeername (Socket.S.FD, Name'Address, Len'Access) = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;

      return Positive
               (Swap_Little_Endian (Interfaces.Unsigned_16 (Name.Port)));
   end Peer_Port;

   -------------
   -- Pending --
   -------------

   overriding function Pending
     (Socket : Socket_Type) return Stream_Element_Count
   is
      use type C.int;
      Arg : aliased C.int;
      Res : constant C.int := OS_Lib.C_Ioctl
                                (Socket.S.FD,
                                 OS_Lib.FIONREAD,
                                 Arg'Unchecked_Access);
   begin
      if Res = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;

      return Stream_Element_Count (Arg);
   end Pending;

   ------------------------
   -- Raise_Socket_Error --
   ------------------------

   procedure Raise_Socket_Error (Error : Integer; Socket : Socket_Type) is
   begin
      Raise_Socket_Error (Socket, Error_Message (Error));
   end Raise_Socket_Error;

   procedure Raise_Socket_Error (Error : Integer) is
   begin
      Raise_Socket_Error (Error_Message (Error));
   end Raise_Socket_Error;

   procedure Raise_Socket_Error (Errmsg : String) is
   begin
      Raise_Socket_Error
        (Socket_Type'(Net.Socket_Type with S => null), Errmsg);
   end Raise_Socket_Error;

   -------------
   -- Receive --
   -------------

   overriding procedure Receive
     (Socket : Socket_Type;
      Data   : out Stream_Element_Array;
      Last   : out Stream_Element_Offset)
   is
      use type C.int;

      Res : C.int;

      function C_Recv
        (S     : C.int;
         Msg   : System.Address;
         Len   : C.int;
         Flags : C.int) return C.int;
      pragma Import (Stdcall, C_Recv, "recv");

   begin
      Wait_For (Input, Socket);

      Res := C_Recv
        (Socket.S.FD,
         Data (Data'First)'Address,
         Data'Length,
         0);

      if Res = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);

      elsif Res = 0 then
         --  socket closed by peer
         raise Socket_Error with "Receive : Socket closed by peer.";
      end if;

      Last := Data'First + Ada.Streams.Stream_Element_Offset (Res - 1);

      if Net.Log.Is_Write_Active then
         Net.Log.Write
           (Direction => Net.Log.Received,
            Socket    => Socket,
            Data      => Data,
            Last      => Last);
      end if;
   end Receive;

   ----------
   -- Send --
   ----------

   overriding procedure Send
     (Socket : Socket_Type;
      Data   : Stream_Element_Array;
      Last   : out Stream_Element_Offset)
   is
      use type C.int;

      Errno : Integer;
      RC    : C.int;

      function C_Sendto
        (S     : C.int;
         Msg   : System.Address;
         Len   : C.int;
         Flags : C.int;
         To    : access Sockaddr_In6;
         Tolen : C.int) return C.int;
      pragma Import (StdCall, C_Sendto, "sendto");

   begin
      RC := C_Sendto
              (Socket.S.FD,
               Data'Address,
               Data'Length,
               OS_Lib.MSG_NOSIGNAL, null, 0);

      if RC = Failure then
         Errno := OS_Lib.Socket_Errno;

         if Errno = OS_Lib.EWOULDBLOCK then
            Last := Last_Index (Data'First, 0);
            return;

         else
            Raise_Socket_Error (Errno, Socket);
         end if;
      end if;

      Last := Last_Index (Data'First, Natural (RC));

      if Net.Log.Is_Write_Active then
         Net.Log.Write
           (Direction => Net.Log.Sent,
            Socket    => Socket,
            Data      => Data,
            Last      => Last);
      end if;
   end Send;

   ----------------------
   -- Set_Int_Sock_Opt --
   ----------------------

   procedure Set_Int_Sock_Opt
     (Socket : Socket_Type;
      Name   : Interfaces.C.int;
      Value  : Integer;
      Level  : Interfaces.C.int := OS_Lib.SOL_SOCKET)
   is
      use type C.int;

      Res : constant C.int :=
              OS_Lib.Set_Sock_Opt
                (Socket.S.FD,
                 Level,
                 Name,
                 Value'Address,
                 Value'Size / System.Storage_Unit);

   begin
      if Res = Failure then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;
   end Set_Int_Sock_Opt;

   ------------------
   -- Set_No_Delay --
   ------------------

   overriding procedure Set_No_Delay
     (Socket : Socket_Type; Value : Boolean := True) is
   begin
      Set_Int_Sock_Opt
        (Socket,
         Name  => OS_Lib.TCP_NODELAY,
         Level => OS_Lib.IPPROTO_TCP,
         Value => Boolean'Pos (Value));
   end Set_No_Delay;

   ---------------------------
   -- Set_Non_Blocking_Mode --
   ---------------------------

   procedure Set_Non_Blocking_Mode (Socket : Socket_Type) is
      use type C.int;
      Enabled : aliased C.int := 1;
   begin
      if OS_Lib.C_Ioctl (Socket.S.FD, OS_Lib.FIONBIO, Enabled'Access) /= 0 then
         Raise_Socket_Error (OS_Lib.Socket_Errno, Socket);
      end if;
   end Set_Non_Blocking_Mode;

   -----------------------------
   -- Set_Receive_Buffer_Size --
   -----------------------------

   overriding procedure Set_Receive_Buffer_Size
     (Socket : Socket_Type; Size : Natural) is
   begin
      Set_Int_Sock_Opt (Socket, OS_Lib.SO_RCVBUF, Size);
   end Set_Receive_Buffer_Size;

   --------------------------
   -- Set_Send_Buffer_Size --
   --------------------------

   overriding procedure Set_Send_Buffer_Size
     (Socket : Socket_Type; Size : Natural) is
   begin
      Set_Int_Sock_Opt (Socket, OS_Lib.SO_SNDBUF, Size);
   end Set_Send_Buffer_Size;

   --------------
   -- Shutdown --
   --------------

   overriding procedure Shutdown
     (Socket : Socket_Type; How : Shutmode_Type := Shut_Read_Write)
   is
      use type C.int;
      FD    : constant C.int := Socket.S.FD;
      EN    : Integer;
      To_OS : constant array (Shutmode_Type) of C.int :=
                (Shut_Read_Write => OS_Lib.SHUT_RDWR,
                 Shut_Read       => OS_Lib.SHUT_RD,
                 Shut_Write      => OS_Lib.SHUT_WR);

      function C_Shutdown (S : C.int; How : C.int) return C.int;
      pragma Import (Stdcall, C_Shutdown, "shutdown");

   begin
      if Net.Log.Is_Event_Active then
         Net.Log.Event (Net.Log.Shutdown, Socket);
      end if;

      if C_Shutdown (FD, To_OS (How)) = Failure then
         EN := OS_Lib.Socket_Errno;

         if EN /= OS_Lib.ENOTCONN then
            Log.Error (Socket, Error_Message (EN));
         end if;
      end if;

      --  Avoid any activity under closed socket in other threads.
      --  Reduce risk to send/receive data on other new created sockets.

      if How /= Shut_Read_Write then
         return;
      end if;

      Socket.S.FD := No_Socket;

      if OS_Lib.C_Close (FD) = Failure then
         --  Back true FD for logging

         Socket.S.FD := FD;
         Log.Error (Socket, Error_Message (OS_Lib.Socket_Errno));
         Socket.S.FD := No_Socket;
      end if;
   end Shutdown;

   ------------------------
   -- Swap_Little_Endian --
   ------------------------

   function Swap_Little_Endian (S : Unsigned_16) return Unsigned_16 is
      use System;
      Big_Endian : constant Boolean := Default_Bit_Order = High_Order_First;
   begin
      if Big_Endian then
         return S;
      else
         return Interfaces.Rotate_Left (S, 8);
      end if;
   end Swap_Little_Endian;

   WSA_Data_Dummy : array (1 .. 512) of C.int;

begin
   OS_Lib.WSA_Startup (16#0202#, WSA_Data_Dummy'Address);
end AWS.Net.Std;