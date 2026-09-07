# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "tmpdir"

# Manuel/songbook/options.adoc, "Elles se mettent dans la section options:" — les
# options du carnet (imbriquées, ex. `diags:/align:`) doivent se lire À LA RACINE de
# l'arbre MÊME quand écrites (comme documenté) sous une section `options:`.
RSpec.describe "CarnetBuilder.parse_nested_infos — section options: (bug constaté, Carnet-1)" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write_infos(content)
    path = File.join(@dir, "c.infos")
    File.write(path, content)
    path
  end

  it "clé imbriquée SOUS options: (convention documentée) : lue à la racine de l'arbre" do
    path = write_infos(<<~YAML)
      title: Carnet 1
      options:
        diags:
          align: Left
    YAML

    tree = CarnetBuilder.parse_nested_infos(path)
    expect(tree["diags"]).to eq({ "align" => "Left" })
  end

  it "clé imbriquée déjà à la racine (convention chanson, sans options:) : inchangée" do
    path = write_infos(<<~YAML)
      diags:
        size: 32pt x
    YAML

    tree = CarnetBuilder.parse_nested_infos(path)
    expect(tree["diags"]).to eq({ "size" => "32pt x" })
  end

  it "une clé présente aux DEUX endroits : celle de la racine gagne, jamais écrasée par options:" do
    path = write_infos(<<~YAML)
      diags:
        align: Right
      options:
        diags:
          align: Left
    YAML

    tree = CarnetBuilder.parse_nested_infos(path)
    expect(tree["diags"]).to eq({ "align" => "Right" })
  end

  it "résolution complète (Options.load!) : diags_align vaut bien la valeur imbriquée sous options:" do
    carnet_dir = @dir
    write_infos(<<~YAML)
      title: Carnet 1
      options:
        diags:
          align: Left
    YAML
    song_infos = File.join(Dir.mktmpdir, "c.infos")
    File.write(song_infos, "title: Chanson\n")

    Options.load!(meta: {}, infos_path: song_infos, carnet_folder: carnet_dir)

    expect(Options.get(:diags_align)).to eq("Left")
  end
end
