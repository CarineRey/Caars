(*
# File: trinity.ml
# Created by: Carine Rey
# Created on: March 2016
#
#
# Copyright 2016 Carine Rey
# This software is a computer program whose purpose is to assembly
# sequences from RNA-Seq data (paired-end or single-end) using one or
# more reference homologous sequences.
# This software is governed by the CeCILL license under French law and
# abiding by the rules of distribution of free software.  You can  use,
# modify and/ or redistribute the software under the terms of the CeCILL
# license as circulated by CEA, CNRS and INRIA at the following URL
# "http://www.cecill.info".
# As a counterpart to the access to the source code and  rights to copy,
# modify and redistribute granted by the license, users are provided only
# with a limited warranty  and the software's author,  the holder of the
# economic rights,  and the successive licensors  have only  limited
# liability.
# In this respect, the user's attention is drawn to the risks associated
# with loading,  using,  modifying and/or developing or reproducing the
# software by the user in light of its specific status of free software,
# that may mean  that it is complicated to manipulate,  and  that  also
# therefore means  that it is reserved for developers  and  experienced
# professionals having in-depth computer knowledge. Users are therefore
# encouraged to load and test the software's suitability as regards their
# requirements in conditions enabling the security of their systems and/or
# data to be ensured and,  more generally, to use and operate it in the
# same conditions as regards security.
# The fact that you are presently reading this means that you have had
# knowledge of the CeCILL license and that you accept its terms.
*)

open Core_kernel
open Bistro
open Bistro.Shell_dsl
open Wutils
open Defs

let single_stranded_or_unstranded = function
  | F -> string "--SS_lib_type F"
  | R -> string "--SS_lib_type R"
  | US -> string ""

let paired_stranded_or_unstranded = function
  | RF -> string "--SS_lib_type RF"
  | FR -> string "--SS_lib_type FR"
  | UP -> string ""

let config_trinity_fasta_paired_or_single = function
  | OSE_or_PE.Single_end se ->
    seq ~sep: " " [ string "--single" ; dep se.reads ; single_stranded_or_unstranded se.orientation ]
  | Paired_end pe ->
    seq ~sep: " " [ string "--left" ; dep pe.reads1 ; string "--right" ; dep pe.reads2 ; paired_stranded_or_unstranded pe.orientation ]

let fasta_read_normalization_get_output ~fasta ~dest=
  let (vars, code) = match fasta with
    | OSE_or_PE.Single_end _ -> (["DEST", dest;
                                  "SINGLELINK", string "`readlink single.norm.fa`"],
                                 {| mv $SINGLELINK $DEST/"single.norm.fa"|})
    | Paired_end _ -> (["DEST", dest;
                        "LEFTLINK", string "`readlink left.norm.fa`";
                        "RIGHTLINK", string "`readlink right.norm.fa`"],
                       {|echo $LEFTLINK ; mv $LEFTLINK $DEST/"left.norm.fa"; mv $RIGHTLINK $DEST/"right.norm.fa"|})
  in
  Wutils.bash_script vars code

let fasta_read_normalization
    ?(descr = "")
    ~max_cov
    ~threads
    ?(memory = 1)
    ?(max_memory = 1)
    (fasta : fasta file OSE_or_PE.t)
  : fasta file OSE_or_PE.t =
  let bistro_memory =
    if max_memory > 2 then Int.(min max_memory (memory * 2))
    else 1
  in
  let given_mem =
    if bistro_memory > 2 then Int.(bistro_memory / 2)
    else 1
  in
  (* reserve more memory by bistro than given to normalization tools*)
  let output_dir =
    Workflow.shell ~descr:("fasta_read_normalization" ^ descr) ~version:2 ~np:threads ~mem:(Workflow.int (1024 * bistro_memory)) [
      mkdir_p dest;
      mkdir_p tmp ;
      within_container caars_img (
        and_list [
          cmd "Trinity" [
            string "--no_version_check";
            opt "--max_memory" seq [ string "$((" ; int given_mem ; string " / 1024))G" ] ;
            opt "--CPU" Fn.id np ;
            string "--just_normalize_reads";
            opt "--normalize_max_read_cov" int max_cov ;
            config_trinity_fasta_paired_or_single fasta ;
            string "--seqType fa" ;
            opt "--output" seq [ tmp ; string "/trinity"] ;
          ];
          cd (tmp // "trinity/insilico_read_normalization") ;
          cmd "sh" [ file_dump (fasta_read_normalization_get_output ~fasta ~dest) ];
        ]
      )
    ]
  in
  match fasta with
  | Single_end se -> OSE_or_PE.se (Workflow.select output_dir ["single.norm.fa"]) se.orientation
  | Paired_end pe ->
    OSE_or_PE.pe
      (Workflow.select output_dir ["left.norm.fa"])
      (Workflow.select output_dir ["right.norm.fa"])
      pe.orientation

let trinity_fasta
    ?tag
    ?full_cleanup
    ?no_normalization
    ~threads
    ?(memory = 1)
    (sample_fasta : fasta file OSE_or_PE.t)
  : fasta file =
  Workflow.shell ~descr:(descr ?tag "Trinity") ~np:threads ~mem:(Workflow.int (1024 * memory)) [
    mkdir_p dest;
    cmd "Trinity" ~img:caars_img [
      string "--no_version_check";
      opt "--max_memory" ident (seq [ string "$((" ; mem ; string " / 1024))G" ]) ;
      opt "--CPU" ident np ;
      option (flag string "--full_cleanup") full_cleanup ;
      option (flag string "--no_normalize_reads") no_normalization ;
      config_trinity_fasta_paired_or_single sample_fasta;
      string "--seqType fa" ;
      opt "--output" seq [ ident dest ; string "/trinity"] ;
    ];
    cmd "sed" [
      string "-re";
      string {|"s/(>[_a-zA-Z0-9]*)( len=[0-9]* path=.*)/\1/"|};
      string "-i";
      seq [ident dest; string "/trinity.Trinity.fasta";];
    ];
  ]
  |> Fn.flip Workflow.select [ "trinity.Trinity.fasta" ]

let fastq2fasta ?(descr="") (fastq : #fastq file) :  fasta file =
  let descr = if String.is_empty descr then descr else ":" ^ descr in
  let script =
    let vars = [
      "FQ", dep fastq ;
      "DEST", dest ;
    ]
    in
    bash_script vars {|seqtk seq -A $FQ > $DEST|}
  in
  Workflow.shell ~descr:("fastq2fasta" ^ descr) ~np:1 [
    cmd "sh" ~img:caars_img [ file_dump script ];
  ]

let assembly_stats ?(descr="") (fasta:fasta file) : text file =
  let descr = if String.is_empty descr then descr else ":" ^ descr ^ " " in
  let script =
    let vars = [
      "TRINITY_PATH", string "`which Trinity`" ;
      "TRINTIY_DIR_PATH", string "`dirname $TRINITY_PATH`" ;
      "TRINITYSTATS_PATH", string "$TRINTIY_DIR_PATH/util/TrinityStats.pl" ;
      "FASTA" , dep fasta ;
      "DEST", dest ;
    ]
    in
    bash_script vars {|
if [ -s $FASTA ]
then
$TRINITYSTATS_PATH $FASTA > $DEST
else
echo "Empty file" > $DEST
fi
|}
  in
  Workflow.shell ~descr:("assembly_stats_trinity" ^ descr) ~np:1 [
    cmd "sh" ~img:caars_img [ file_dump script ];
  ]
