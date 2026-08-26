# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"
require "tmpdir"

# Tests des outils
RSpec.describe "niveau de sensibilité aux erreurs (sensitivity)" do
  around do |example|
    Dir.mktmpdir do |dir|
      Layout.conflict_log_path = File.join(dir, "conflicts.log")
      File.write(Layout.conflict_log_path, "")
      example.run
    end
  end

  it "Arrêter tout de suite à la première erreur (high)" do
    Layout.sensitivity = "high"
    expect { Layout.conflict!("problème", solution: "rien") }.to raise_error(RuntimeError, /problème/)
  end

  it "Continuer et raconter toutes les erreurs à la fin (errors)" do
    Layout.sensitivity = "errors"
    expect { Layout.conflict!("problème 1", solution: "rien") }.not_to raise_error
    Layout.conflict!("problème 2", solution: "rien")

    expect { Layout.report_conflicts! }.to output(/problème 1.*problème 2/m).to_stderr
  end

  it "Continuer discrètement, juste dire combien d'erreurs à la fin (log)" do
    Layout.sensitivity = "log"
    Layout.conflict!("problème caché", solution: "rien")
    Layout.conflict!("autre problème caché", solution: "rien")

    expect { Layout.report_conflicts! }.to output(/Des erreurs sont produites \(2\)/).to_stderr
    expect(File.read(Layout.conflict_log_path)).to include("problème caché")
  end

  it "Ne rien dire du tout (low)" do
    Layout.sensitivity = "low"
    expect { Layout.conflict!("problème invisible", solution: "rien") }.not_to raise_error
    expect { Layout.report_conflicts! }.not_to output.to_stderr
  end

  it "Oublier les erreurs d'une construction précédente en recommençant" do
    Layout.sensitivity = "errors"
    Layout.conflict!("vieux problème", solution: "rien")
    Layout.reset_conflicts!

    expect { Layout.report_conflicts! }.not_to output.to_stderr
  end
end
