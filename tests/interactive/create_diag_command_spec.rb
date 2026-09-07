# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require_relative "../../tools/DiagSchem/diagschem"

# Tests du mode interactif — commande `create diag` (issue #79) : diagramme propre à
# la chanson en contexte (`.schemas`/`.sch` DANS son dossier), jamais dans la
# bibliothèque partagée de l'application (`SchemaLibrary`, réservée à l'outil `diag`
# autonome).
RSpec.describe "commande create diag" do
  let(:angie) { File.join(FIXTURE_SONGS_DIR, "Angie") }

  it "refuse sans aucun contexte" do
    expect { CLI.run(%w[create diag], interactive: true) }.to raise_error(SystemExit)
  end

  it "refuse avec seulement un carnet en contexte (jamais dans un carnet)" do
    CLI.run(%w[use songbook Carnet-Test], interactive: true)
    expect { CLI.run(%w[create diag], interactive: true) }.to raise_error(SystemExit)
  end

  it "lance DiagSchem avec song_dir: LA CHANSON en contexte, jamais un schéma pré-rempli si omis" do
    CLI.run(%w[use song Angie], interactive: true)

    instance = instance_double(DiagSchem, run: nil)
    expect(DiagSchem).to receive(:new).with(schema: nil, song_dir: angie).and_return(instance)

    CLI.run(%w[create diag], interactive: true)
  end

  it "avec un schéma en argument : passé tel quel (table pré-remplie, modification)" do
    CLI.run(%w[use song Angie], interactive: true)
    schema = "Am7-0: 10 21/1 32/3 42/2 50 6x"

    instance = instance_double(DiagSchem, run: nil)
    expect(DiagSchem).to receive(:new).with(schema: schema, song_dir: angie).and_return(instance)

    CLI.run(["create", "diag", schema], interactive: true)
  end

  it "--song fixe aussi le contexte pour create diag (Session.with_song)" do
    instance = instance_double(DiagSchem, run: nil)
    expect(DiagSchem).to receive(:new).with(schema: nil, song_dir: angie).and_return(instance)

    CLI.run(["create", "diag", "--song", "Angie"], interactive: true)
  end
end
