require "heroku/client"
require "json"
require "shellwords"
require "sinatra"
require "tmpdir"

class Heroku::Client
  def releases_new(app_name)
    json_decode(get("/apps/#{app_name}/releases/new").to_s)
  end

  def releases_create(app_name, payload)
    json_decode(post("/apps/#{app_name}/releases", json_encode(payload)))
  end

  def release(app_name, slug, description, options={})
    release = releases_new(app_name)
    RestClient.put(release["slug_put_url"], File.open(slug, "rb"), :content_type => nil)
    payload = release.merge({
      "slug_version" => 2,
      "run_deploy_hooks" => true,
      "user" => user,
      "release_descr" => description,
      "head" => Digest::SHA1.hexdigest(Time.now.to_f.to_s)
    }) { |k, v1, v2| v1 || v2 }.merge(options)
    releases_create(app_name, payload)
  end
end

helpers do
  def api(key)
    Heroku::Client.new("", key)
  end

  def auth!
    response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
    throw(:halt, [401, "Unauthorized"])
  end

  def creds
    auth = Rack::Auth::Basic::Request.new(request.env)
    auth.provided? && auth.basic? ? auth.credentials : auth!
  end
end

post "/apps/:app/release" do
  api_key = creds[1]

  halt(403, "must specify build_url") unless params[:build_url]
  halt(403, "must specify description") unless params[:description]

  release = Dir.mktmpdir do |dir|
    escaped_build_url = Shellwords.escape(params[:build_url])

    if params[:build_url] =~ /\.tgz$/
      %x{ mkdir -p #{dir}/tarball }
      %x{ cd #{dir}/tarball && curl #{escaped_build_url} -s -o- | tar xzf - }
      %x{ mksquashfs #{dir}/tarball #{dir}/squash -all-root }
      %x{ cp #{dir}/squash #{dir}/build }
    else
      %x{ curl #{escaped_build_url} -o #{dir}/build 2>&1 }
    end

    %x{ unsquashfs -d #{dir}/extract #{dir}/build Procfile }

    procfile = File.read("#{dir}/extract/Procfile").split("\n").inject({}) do |ax, line|
      ax[$1] = $2 if line =~ /^([A-Za-z0-9_]+):\s*(.+)$/
      ax
    end

    release_options = {
      "process_types" => procfile
    }

    release = api(api_key).release(params[:app], "#{dir}/build", params[:description], release_options)
    release["release"]
  end

  content_type "application/json"
  JSON.dump({ "release" => release })
end
