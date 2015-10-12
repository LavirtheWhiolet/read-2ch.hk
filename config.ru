# encoding: UTF-8
require 'rack'
require 'net/http'
require 'json'
require 'ostruct'
require 'erb'

class Array
  
  def to_h
    reduce({}) { |r, e| r[e[0]] = e[1]; r }
  end
  
end

class Object
  
  # passes this Object to +f+ and returns +f+'s result.
  def map1(&f)
    f.(self)
  end
  
end

class Net::HTTPResponse
  
  def headers
    h = {}
    each_header { |key, value| h[key] = value }
    return h
  end
  
end

class Hash
  
  def reject_keys(*keys)
    reject { |key, value| keys.include? key }
  end
  
  # +f+ is passed with value at +key+.
  # 
  # It returns Hash with the new entry.
  # 
  # If this Hash does not have +key+ then it just returns this Hash.
  # 
  def rewrite(key, &f)
    if self.has_key? key then self[key] = f.(self[key]); end
    self
  end
  
end

class String
  
  def if_not_empty(&f)
    if not empty? then f.(self)
    else self
    end
  end
  
end

module Utils

  # Note: it calls +close+ on +rack_response_body+ if applicable.
  def read1(rack_response_body)
    body = ""
    rack_response_body.each { |part| body << part }
    rack_response_body.close() if rack_response_body.respond_to? :close
    return body
  end

  # forwards Rack +env+ to host at +host_uri+ (URI).
  # 
  # +SCRIPT_NAME+ is ignored.
  # 
  # It returns Rack::Response.
  # 
  # TODO: Do not read entire host response body.
  # 
  def forward(env, host_uri)
    headers = env.
      map { |key, value| [key[/^HTTP_(.*)/, 1] || key[/^(CONTENT_.*)/, 1], value] }.
      reject { |key, value| key.nil? }.
      map { |key, value| [key.tr("_", "-"), value] }.
      to_h.
      merge("HOST" => host_uri.host).
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
        r.body_stream = env["rack.input"] if r.request_body_permitted?
      end
    host_response =
      Net::HTTP.start(host_uri.host, host_uri.port, :use_ssl => host_uri.scheme == 'https') do |http|
        http.request(host_request)
      end
    return Rack::Response.new(
      host_response.body || "",
      host_response.code,
      host_response.headers.
        map do |key, value|
          case key.downcase
          when "set-cookie"
            # TODO: Process "domain" parameter of "set-cookie" correctly.
            [key, value.gsub(/domain\=(.*?);/, "")]
          when "location"
            if host_response.code.to_i == 301 then
              value = begin
                this_host_uri = URI("http://#{env["HTTP_HOST"]}")
                v = URI(value)
                v.host = this_host_uri.host
                v.port = this_host_uri.port
                v.path = "#{env["SCRIPT_NAME"]}/#{v.path}"
                v.to_s
              end
            end
            [key, value]
          else
            [key, value]
          end
        end
    )
  end
  
  # calls +block+. Inside +block+ you may use #halt().
  def allow_halt(&block)
    catch(:halt, &block)
  end
  
  # returns from +block+ passed to #allow_halt() immediately.
  def halt(allow_halt_result = nil)
    throw(:halt, allow_halt_result)
  end
  
end

class Read2ch_hk
  
  include Utils
  
  def call(env)
    call0(env).finish()
  end
  
  private
  
  def call0(env)
    allow_halt do
      if /^\/(?<board>.*?)\/res\/(?<thread>.*?)\.html$/ =~ env["PATH_INFO"] and
          board != "test"
        dvach_hk_response = begin
          path = "/#{board}/res/#{thread}.json"
          request = env.
            merge(
              "HTTP_ACCEPT" => "application/json; charset=utf-8",
              "PATH_INFO" => path,
              "REQUEST_PATH" => path,
              "REQUEST_URI" => path
            ).
            reject_keys(
              "HTTP_ACCEPT_ENCODING",
              "HTTP_CONNECTION_KEEP_ALIVE"
            )
          forward_to_2ch_hk_and_unhide_some_content(request)
        end
        if dvach_hk_response.status != 200 then
          halt(dvach_hk_response)
        end
        posts = dvach_hk_response.body.
          map1 { |b| JSON.parse("{\"data\": #{read1(b)}}")['data'] }.
          tap { |b| halt(Rack::Response.new(b["Error"], 503)) if b.is_a? Hash and b.key? "Error" }.
          map1 { |b| b['threads'][0]['posts'] }.
          map do |post|
            post = OpenStruct.new(post)
            post.files ||= []
            post.files.map! { |file| OpenStruct.new(file) }
            post
          end.
          each_with_index { |post, i| post.rel_num = i+1 }
        return Rack::Response.new(
          thread_html(board, posts),
          200,
          "Content-Type" => "text/html; charset=utf8"
        )
      else
        forward_to_2ch_hk_and_unhide_some_content(env)
      end
    end
  end
  
  private
  
  # Modifies +env+ to unhide some content on 2ch.hk which is hidden due to
  # Mizulina's rampage and Utils#forward()-s it to 2ch.hk.
  def forward_to_2ch_hk_and_unhide_some_content(env)
    unhiding_cookie = "usercode_auth=24ffaf6d82692d95746a61ef1c1436ce"
    env =
      {
        "HTTP_COOKIE" => unhiding_cookie
      }.
      merge(env).
      rewrite("HTTP_COOKIE") do |value|
        if not value =~ /usercode_auth\=/ then
          value += "#{value}; #{unhiding_cookie}"
        else
          value
        end
      end
    forward(env, URI("http://2ch.hk"))
  end
  
  def thread_html(board, posts)
    ERB.new(<<-ERB).result(binding)
<html>
<head>
  <style>
    * {
      font-family: serif;
    }
    .reply {
      padding: 0.8em;
      margin-bottom: 0.25em;
      border: 1px solid #CCC;
      border-radius: 5px;
    }
    .post_file {
      display: inline;
      margin-right: 0.8em;
      margin-top: 0.8em;
      margin-bottom: 0.8em;
    }
    .post_header {
      margin-bottom: 0.5em;
      font-size: smaller;
      color: #999;
    }
    .post_rel_num {
      color: inherit;
      font-weight: bold;
      text-decoration: none;
    }
    .post_num {
      color: inherit;
      text-decoration: none;
    }
    .post_name {
      color: inherit;
      /*font-style: italic;*/
    }
    .post_date {
    }
    .post_subject {
      color: inherit;
      font-weight: bold;
    }
    span.spoiler, span.spoiler a {
      background: #BBB;
      color: #BBB;
    }
    span.spoiler:hover, span.spoiler:hover a {
      background: inherit;
      color: inherit;
    }
  </style>
</head>
<body>

<% for post in posts %>
<div class="reply">
  <div class="post_header">
    <a class="post_rel_num" id="rel<%=post.rel_num%>" href="#rel<%=post.rel_num%>">№<%=post.rel_num%>.</a>
    <a class="post_num" id="<%=post.num%>" href="#<%=post.num%>">#<%=post.num%></a>
    <% if post.email.empty? %> <span class="post_name"><%=post.name%></span> <% else %> <a class="post_name" href="<%=post.email%>"><%=post.name%></a> <% end %>
    <span class="post_subject"><%=post.subject%></span>
    (<span class="post_date"><%=post.date%></span>)
  </div>
  <% for post_file in post.files %>
  <div class="post_file"><a href="/<%=board%>/<%=post_file.path%>"><img src="/<%=board%>/<%=post_file.thumbnail%>" name="<%=post_file.name%>"/></a></div>
  <% end %>
  <% if not post.files.empty? then %> <p/> <% end %>
  <%=post.comment%>
</div>
<% end %>

</body>
</html>
    ERB
  end

end

run Read2ch_hk.new
