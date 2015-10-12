require 'rack'
require 'net/http'
require 'json'
require 'ostruct'

class Array
  
  def to_h
    reduce({}) { |r, e| r[e[0]] = e[1]; r }
  end
  
end

class Hash
  
  def reject_keys(*keys)
    reject { |key, value| keys.include? key }
  end
  
end

class String
  
  def if_not_empty(&f)
    if not empty? then f.(self)
    else self
    end
  end
  
end

# Note: it calls +close+ on the Rack response's body (if applicable).
def read_body(rack_response)
  body = ""
  rack_body = rack_response[2]
  rack_body.each { |part| body << part }
  rack_body.close() if rack_body.respond_to? :close
  return body
end

# forwards Rack +env+ to host at +host_uri+ (URI).
# 
# +SCRIPT_NAME+ is ignored.
# 
# It returns Rack response.
# 
def forward(env, host_uri)
  headers = env.
    map { |key, value| [key[/^HTTP_(.*)/, 1] || key[/^(CONTENT_.*)/, 1], value] }.
    reject { |key, value| key.nil? }.
    map { |key, value| [key.tr("_", "-"), value] }.
    to_h.
    merge("HOST" => host).
    # TODO: Process "REFERER" header correctly.
    reject_keys("REFERER")
  host_request =
    case env["REQUEST_METHOD"]
    when "GET" then Net::HTTP::Get
    when "POST" then Net::HTTP::Post
    when "HEAD" then Net::HTTP::Head
    else raise "#{env["REQUEST_METHOD"]} requests forwarding is not implemented"
    end.
    new(
      env["PATH_INFO"] + env["QUERY_STRING"].if_not_empty { |q| "?#{q}" },
      headers
    ).
    tap do |r|
      r.body_stream = env["rack.input"]
    end
  host_response =
    Net::HTTP.start(host_uri.host, host_uri.port, :use_ssl => uri.scheme == 'https') do |http|
      http.request(host_request)
    end
  [
    host_response.code,
    host_response.headers.
      map do |key, value|
        case key.downcase
        when "set-cookie"
          # TODO: Process "domain" parameter of "set-cookie" correctly.
          [key, value.gsub(/domain\=(.*?);/, "")]
        else
          [key, value]
        end
      end,
    [host_response.body]
  ]
end

run(lambda do |env|
  forward(env, URI("http://2ch.hk"))
end)
