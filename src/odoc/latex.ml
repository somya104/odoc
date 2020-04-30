open Odoc_document

type args = {
  with_children : bool ;
}

let render args page =
  Odoc_latex.Generator.render ~with_children:args.with_children page

let renderer = {Renderer.
  render ;
}
