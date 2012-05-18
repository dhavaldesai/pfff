(* Yoann Padioleau
 * 
 * Copyright (C) 2012 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common
(* floats are the norm in graphics *)
open Common.ArithFloatInfix

module G = Gui
module K = GdkKeysyms

module CairoH = Cairo_helpers3

module Model = Model3
module Controller = Controller3
open Model3
module View_overlays = View_overlays3

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Wrappers *)
(*****************************************************************************)

(*****************************************************************************)
(* Globals *)
(*****************************************************************************)
(* when some widgets need to access other widgets *)

(*****************************************************************************)
(* Final view rendering *)
(*****************************************************************************)

(* Composing the "layers". See cairo/tests/knockout.ml example.
 * Each move of the cursor will call assemble_layers which does all
 * those pixels copying (but this is fast enough).
 *)
let assemble_layers cr_final w =
  let surface_src = CairoH.surface_of_pixmap w.pm in

  Cairo.set_operator cr_final Cairo.OPERATOR_OVER;
  Cairo.set_source_surface cr_final surface_src 0. 0.;
  Cairo.paint cr_final;

  Cairo.set_operator cr_final Cairo.OPERATOR_OVER;
  Cairo.set_source_surface cr_final w.overlay 0. 0.;
  Cairo.paint cr_final;
  ()

let expose da w ev = 
  let gwin = da#misc#window in
  let cr = Cairo_lablgtk.create gwin in
  assemble_layers cr w;
  true

let configure da w ev =
  let width = GdkEvent.Configure.width ev in
  let height = GdkEvent.Configure.height ev in

  (* quite similar to Model.init_world *)
  w.width <- width;
  w.height <- height;
  w.pm <- Model.new_pixmap w.width w.height;
  w.overlay <- 
    Cairo.surface_create_similar (CairoH.surface_of_pixmap w.pm)
     Cairo.CONTENT_COLOR_ALPHA width height;
  View_matrix.paint w;
  true


(*****************************************************************************)
(* The main UI *)
(*****************************************************************************)

let mk_gui w =
  let width = 1350 in
  let height = 800 in

  let win = GWindow.window
    ~title:"CodeGraph"
    ~width ~height
    ~allow_shrink:true ~allow_grow:true
    ()
  in
  let statusbar = GMisc.statusbar () in
  let ctx = statusbar#new_context "main" in

  Controller._set_title := (fun s -> win#set_title s);
  Controller._statusbar_addtext := (fun s -> ctx#push s +> ignore);

  let accel_group = GtkData.AccelGroup.create () in
  win#misc#set_name "main window";

  let quit () = 
    (*Controller.before_quit_all model;*)
    GMain.Main.quit ();
  in

  win#add_accel_group accel_group;

  (*-------------------------------------------------------------------*)
  (* Layout *)
  (*-------------------------------------------------------------------*)

  (* if use my G.mk style for that, then get some pbs when trying
   * to draw stuff :(
   *)
  let vbox = GPack.vbox ~packing:win#add () in

    (*-------------------------------------------------------------------*)
    (* Menu *)
    (*-------------------------------------------------------------------*)
    vbox#pack (G.mk (GMenu.menu_bar) (fun m -> 

      let factory = new GMenu.factory m in
      factory#add_submenu "_File" +> (fun menu -> 
        let fc = new GMenu.factory menu ~accel_group in

        fc#add_item "_Open stuff from db" ~key:K._O ~callback:(fun () -> 
          raise Todo
        ) +> ignore;
        fc#add_separator () +> ignore;

        fc#add_item "_Quit" ~key:K._Q ~callback:quit +> ignore;
      );

      factory#add_submenu "_Edit" +> (fun menu -> 
        GToolbox.build_menu menu ~entries:[
          `S;
        ];
      ) +> ignore;

      factory#add_submenu "_Move" +> (fun menu -> 
        let fc = new GMenu.factory menu ~accel_group in

        fc#add_item "_Go back" ~key:K._B ~callback:(fun () -> 
          raise Todo
          (*!Controller._go_back dw *)
        ) +> ignore;
      );

      factory#add_submenu "_Search" +> (fun menu -> 
        let _fc = new GMenu.factory menu ~accel_group in
        ()
      );

      factory#add_submenu "_Misc" +> (fun menu -> 
        let fc = new GMenu.factory menu ~accel_group in

        fc#add_item "_Refresh" ~key:K._R ~callback:(fun () -> 
          raise Todo
        ) +> ignore;
      );

      factory#add_submenu "_Help" +> (fun menu -> 
        let fc = new GMenu.factory menu ~accel_group in

        fc#add_separator () +> ignore;
        fc#add_item "About" ~callback:(fun () -> 
            G.dialog_text "Brought to you by pad\nwith love" "About"
        ) +> ignore;
      );

    ));

    (*-------------------------------------------------------------------*)
    (* toolbar *)
    (*-------------------------------------------------------------------*)
    vbox#pack (G.mk (GButton.toolbar) (fun tb ->

      tb#insert_widget (G.mk (GButton.button ~stock:`GO_BACK) (fun b -> 
        b#connect#clicked ~callback:(fun () -> 
          raise Todo
          (* !Controller._go_back dw;*)
        )
      ));
    ));

    (*-------------------------------------------------------------------*)
    (* main view *)
    (*-------------------------------------------------------------------*)

    let vpane = GPack.paned `VERTICAL
      ~packing:(vbox#pack ~expand:true ~fill:true) () in

    let da = GMisc.drawing_area () in
    da#misc#set_double_buffered false;

    vpane#add1 da#coerce;

    da#misc#set_can_focus true ;
    da#event#add [ `KEY_PRESS;
                   `BUTTON_MOTION; `POINTER_MOTION;
                   `BUTTON_PRESS; `BUTTON_RELEASE ];

    da#event#connect#expose ~callback:(expose da w) +> ignore;
    da#event#connect#configure ~callback:(configure da w) +> ignore;

    da#event#connect#button_press   
      (View_matrix.button_action da w) +> ignore;
    da#event#connect#button_release 
      (View_matrix.button_action da w) +> ignore;

    da#event#connect#motion_notify  
      (View_overlays.motion_notify da w) +> ignore; 

    Controller._refresh_da := (fun () ->
      GtkBase.Widget.queue_draw da#as_widget;
    );

    (*-------------------------------------------------------------------*)
    (* status bar *)
    (*-------------------------------------------------------------------*)
    vbox#pack (*~from: `END*) statusbar#coerce;

  (*-------------------------------------------------------------------*)
  (* End *)
  (*-------------------------------------------------------------------*)

  GtkSignal.user_handler := (fun exn -> 
    pr2 "fucking callback";
    (* old: before 3.11: Features.Backtrace.print(); *)
    let s = Printexc.get_backtrace () in
    pr2 s;
    let pb = "pb: " ^ string_of_exn exn in
    G.dialog_text ~text:pb ~title:"pb";
    raise exn
  );

  win#event#connect#delete    ~callback:(fun _  -> quit(); true) +> ignore;
  win#connect#destroy         ~callback:(fun () -> quit(); ) +> ignore;
  win#show ();


  GtkThread.main ();
  ()
