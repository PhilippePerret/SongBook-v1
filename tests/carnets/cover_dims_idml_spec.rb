# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "carnet_builder"
require "fileutils"

# Tests des carnets
RSpec.describe "couverture d'un carnet" do
  let(:carnet_folder) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test") }
  let(:export_dir) { File.join(carnet_folder, "export") }

  before do
    CarnetBuilder.build(carnet_folder) # nécessaire : dims/idml lisent le nombre de pages du dernier PDF construit
    CLI.run(["use", "songbook", "Carnet-Test"], interactive: true)
  end

  after { FileUtils.rm_rf(export_dir) }

  it "Donner toutes les dimensions d'impression de la couverture" do
    expect { CLI.run(%w[cover dims], interactive: true) }.to output(/dos|spine|couverture complète/).to_stdout
  end

  it "Refuser de donner les dimensions si le carnet n'a jamais été construit" do
    FileUtils.rm_rf(File.join(export_dir, "songbooks"))
    expect { CLI.run(%w[cover dims], interactive: true) }.to raise_error(SystemExit)
  end

  it "Produire le modèle IDML de la couverture complète" do
    CLI.run(%w[cover idml], interactive: true)
    expect(File.exist?(File.join(export_dir, "cover", "carnet-test-cover.idml"))).to be true
  end
end
