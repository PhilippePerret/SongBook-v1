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

  it "Utiliser la couverture propre au carnet plutôt que celle par défaut" do
    custom_cov = File.join(carnet_folder, "c.cov")
    File.write(custom_cov, "1.\n{title}\n\n4.\n{price}\n")

    begin
      expect(CoverBuilder).to receive(:build).with(anything, hash_including(cov_path: custom_cov))
      CarnetBuilder.build(carnet_folder, cover: true)
    ensure
      File.delete(custom_cov)
    end
  end

  describe "carnet hors des plages de pages KDP" do
    let(:small_carnet) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Small") }
    let(:small_export_dir) { File.join(small_carnet, "export") }

    before do
      FileUtils.mkdir_p(small_carnet)
      File.write(File.join(small_carnet, "c.tdm"), "- Angie\n")
    end

    after { FileUtils.rm_rf(small_carnet) }

    it "n'interrompt plus la construction (avertissement, pas une erreur)" do
      File.write(File.join(small_carnet, "c.infos"), "title: Petit carnet\nprinter: KDP\n")
      out_path = nil
      expect { out_path = CarnetBuilder.build(small_carnet) }.to output(/Attention.*inférieur aux plages KDP \(24 à 828\)/).to_stdout
      expect(File.exist?(out_path)).to be true
    end

    it "n'affiche rien si 'printer' n'est ni Amazon ni KDP" do
      File.write(File.join(small_carnet, "c.infos"), "title: Petit carnet\n")
      expect { CarnetBuilder.build(small_carnet) }.not_to output(/Attention/).to_stdout
    end

    it "'printer' insensible à la casse (amazon/kdp)" do
      File.write(File.join(small_carnet, "c.infos"), "title: Petit carnet\nprinter: amazon\n")
      expect { CarnetBuilder.build(small_carnet) }.to output(/Attention/).to_stdout
    end
  end
end
