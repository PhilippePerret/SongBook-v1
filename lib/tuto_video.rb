# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Vidéo provisoire du tutoriel d'une chanson (`<id>.mp4` dans `CHANSONS_TUTOS_DIR`),
# produite par ScreenFlow à partir du modèle `tuto.screenflow` : titre (en capitales,
# centré) et performer remplacés, puis export piloté par l'interface de ScreenFlow.
module TutoVideo
  CHANSONS_TUTOS_DIR = "/Users/philippeperret/Documents/Musique/Carnets-de-chant/Divers/Icare-video-guitare/chansons-tutos"
  TOOLS_DIR = File.expand_path("../tools/ScreenFlowTuto", __dir__)
  TEMPLATE = File.join(TOOLS_DIR, "tuto.screenflow")

  # Cloudflare R2 (API S3, outil `aws`, identifiants dans le profil `r2`).
  R2_ACCOUNT_ID = "82a2f50564a14dadc4ababdd1c5199b5"
  R2_BUCKET = "chansons-tutos"
  R2_PROFILE = "r2"
  R2_ENDPOINT = "https://#{R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

  def self.path_for(id, dir = CHANSONS_TUTOS_DIR)
    File.join(dir, "#{id}.mp4")
  end

  # Renvoie `:exists` (vidéo déjà là, rien refait — sauf `force:`), `:created` ou
  # `:failed`.
  def self.produce(id, title, performer, dir = CHANSONS_TUTOS_DIR, force: false)
    mp4 = path_for(id, dir)
    return :exists if File.exist?(mp4) && !force

    Dir.mktmpdir do |tmp|
      doc = File.join(tmp, "#{id}.screenflow")
      ok = system("python3", File.join(TOOLS_DIR, "sf_title.py"), TEMPLATE, doc, title.upcase, performer, mp4, out: File::NULL) &&
           system(File.join(TOOLS_DIR, "sf_export.sh"), doc, mp4, out: File::NULL)
      ok && File.exist?(mp4) ? :created : :failed
    end
  end

  R2_OPTIONS = ["--profile", R2_PROFILE, "--endpoint-url", R2_ENDPOINT].freeze

  # Téléverse `<id>.mp4` à la racine du bucket, en remplaçant toujours la version R2
  # (le fichier local fait foi). Renvoie `:missing` (pas de fichier local),
  # `:uploaded` ou `:failed`.
  def self.upload(id, dir = CHANSONS_TUTOS_DIR)
    mp4 = path_for(id, dir)
    return :missing unless File.exist?(mp4)

    ok = system("aws", "s3", "cp", mp4, "s3://#{R2_BUCKET}/#{File.basename(mp4)}", "--content-type", "video/mp4", *R2_OPTIONS, out: File::NULL)
    ok ? :uploaded : :failed
  end
end
