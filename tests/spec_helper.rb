# frozen_string_literal: true

# Config RSpec pour toute la suite `tests/` — TOUT ce qui concerne les tests vit ICI,
# nulle part ailleurs (Phil). Isole complètement les vrais dossiers de l'user :
# - `AppConfig.songs_dir`/`songbooks_dir` sont TOUJOURS stubbés vers `tests/materiel/`
#   (jamais lus/écrits dans `config.yaml`, jamais un test ne touche aux vrais Carnets/
#   Chansons de Phil).
# - `Session.song`/`Session.carnet` réinitialisés avant CHAQUE exemple (état global).

require "rspec"

APP_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(APP_ROOT, "lib"))

MATERIEL = File.join(__dir__, "materiel")
FIXTURE_SONGS_DIR = File.join(MATERIEL, "Chansons")
FIXTURE_SONGBOOKS_DIR = File.join(MATERIEL, "Carnets")

require "app_config"
require "session"
require "layout"

RSpec.configure do |config|
  config.before do
    allow(AppConfig).to receive(:songs_dir).and_return(FIXTURE_SONGS_DIR)
    allow(AppConfig).to receive(:songbooks_dir).and_return(FIXTURE_SONGBOOKS_DIR)
    allow(AppConfig).to receive(:user_song_editor).and_return("TextEdit")

    Session.song = nil
    Session.carnet = nil

    Layout.sensitivity = "log"
    Layout.reset_conflicts!
  end

  # `CarnetBuilder.build` écrit un cache (`.songs_cache.marshal`) dans le dossier de
  # chansons qu'on lui donne — inoffensif ici (toujours `FIXTURE_SONGS_DIR`, jamais le
  # vrai dossier de Phil), mais un résidu de test ne doit pas traîner d'un run à l'autre.
  config.after(:suite) do
    Dir.glob(File.join(MATERIEL, "**", ".songs_cache.marshal")).each { |f| File.delete(f) }
  end
end
