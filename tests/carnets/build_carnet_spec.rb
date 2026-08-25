# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "fileutils"
require "tmpdir"

# Tests des carnets
RSpec.describe "construction d'un carnet" do
  let(:carnet_folder) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test") }
  let(:export_dir) { File.join(carnet_folder, "export") }

  after { FileUtils.rm_rf(export_dir) }

  it "Construire un carnet complet en PDF" do
    out_path = CarnetBuilder.build(carnet_folder)

    expect(File.exist?(out_path)).to be true
    expect(File.size(out_path)).to be > 0
  end

  it "Refuser un dossier sans table des matières" do
    Dir.mktmpdir do |dir|
      expect { CarnetBuilder.build(dir) }.to raise_error(RuntimeError, /\.tdm/)
    end
  end
end
