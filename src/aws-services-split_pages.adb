------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                            Copyright (C) 2003                            --
--                                ACT-Europe                                --
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

with AWS.Config;
with AWS.MIME;
with AWS.Resources.Streams.Memory;
with AWS.Services.Split_Pages.Uniform;
with AWS.Services.Transient_Pages;
with AWS.Translator;
with Templates_Parser.Query;

package body AWS.Services.Split_Pages is

   -----------
   -- Parse --
   -----------

   function Parse
     (Template     : in String;
      Translations : in Templates.Translate_Set;
      Table        : in Templates.Translate_Set;
      Split_Rule   : in Splitter'Class;
      Cached       : in Boolean := True)
      return Response.Data
   is
      use Templates, Templates.Query;

      procedure Process_Association
        (A    : in     Templates.Association;
         Quit : in out Boolean);
      --  Add A's range into the set if A is a composite object

      Ranges     : constant Ranges_Table
        := Get_Page_Ranges (Split_Rule, Table);
      URIs       : URI_Table (1 .. Ranges'Length);
      Split_Set  : Templates.Translate_Set;
      Result     : Unbounded_String;
      Range_Line : Positive;

      -------------------------
      -- Process_Association --
      -------------------------

      procedure Process_Association
        (A    : in     Templates.Association;
         Quit : in out Boolean)
      is
         pragma Unreferenced (Quit);
      begin
         case Kind (A) is
            when Templates.Std =>
               --  Nothing to be done, copy this association as-is
               Insert (Split_Set, A);

            when Templates.Composite =>
               --  Copy Vector's items in the indicated range
               declare
                  Vector : Tag  renames Composite (A);
                  V      : Templates.Tag;
               begin
                  for K in
                    Ranges (Range_Line).First .. Ranges (Range_Line).Last
                  loop
                     if K <= Templates.Size (Vector) then
                        V := V & Templates.Item (Vector, K);
                     else
                        exit;
                     end if;
                  end loop;

                  Insert (Split_Set, Templates.Assoc (Variable (A), V));
               end;
         end case;
      end Process_Association;

      ------------------------------
      -- Process_All_Associations --
      ------------------------------

      procedure Process_All_Associations is
        new Templates.For_Every_Association (Process_Association);

   begin
      --  Create the set of temporary URIs needed for the pages

      for K in URIs'Range loop
         URIs (K) := To_Unbounded_String (Services.Transient_Pages.Get_URI);
      end loop;

      --  Create each page

      for I in Ranges'Range loop
         --  Create the Split_Table containing part of the items
         Split_Set  := Translations;
         Range_Line := I;
         Process_All_Associations (Table);

         --  Add common tags before calling Get_Translations,
         --  so that they can be replaced if desired.

         Insert (Split_Set, Assoc ("NUMBER_PAGES", URIs'Length));
         Insert (Split_Set, Assoc ("PAGE_NUMBER", I));
         Insert (Split_Set, Assoc ("OFFSET", Ranges (I).First - 1));

         Insert (Split_Set, Get_Translations (Split_Rule, I, URIs, Ranges));

         --  Generate the page, add it to the transient pages handler

         declare
            Stream : AWS.Resources.Streams.Stream_Access;
         begin
            Stream := new AWS.Resources.Streams.Memory.Stream_Type;

            declare
               Page : constant Unbounded_String
                 := Parse (Template, Split_Set, Cached);
            begin
               AWS.Resources.Streams.Memory.Append
                 (AWS.Resources.Streams.Memory.Stream_Type (Stream.all),
                  Translator.To_Stream_Element_Array (To_String (Page)));

               if Result = Null_Unbounded_String then
                  Result := Page;
               end if;
            end;

            Services.Transient_Pages.Register
              (To_String (URIs (I)), Stream, Config.Transient_Lifetime);
         end;
      end loop;

      return Response.Build (MIME.Text_HTML, Result);
   end Parse;

   function Parse
     (Template     : in String;
      Translations : in Templates.Translate_Table;
      Table        : in Templates.Translate_Table;
      Split_Rule   : in Splitter'Class;
      Cached       : in Boolean  := True)
      return Response.Data is
   begin
      return Parse
        (Template,
         Templates.To_Set (Translations),
         Templates.To_Set (Table),
         Split_Rule,
         Cached);
   end Parse;

   function Parse
     (Template     : in String;
      Translations : in Templates.Translate_Table;
      Table        : in Templates.Translate_Table;
      Max_Per_Page : in Positive := 25;
      Max_In_Index : in Positive := 20;
      Cached       : in Boolean  := True)
      return Response.Data
   is
      pragma Unreferenced (Max_In_Index);
      S : Uniform.Splitter (Max_Per_Page);
   begin
      return Parse (Template, Translations, Table, S, Cached);
   end Parse;

end AWS.Services.Split_Pages;
