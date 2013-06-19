require 'erb'
require 'sinatra/base'
require 'rack/csrf'
require 'models'
require 'json'
require 'forme/sinatra'
require './lib/kaeruera/recorder'

Forme.register_config(:mine, :base=>:default, :serializer=>:html_usa, :labeler=>:explicit, :wrapper=>:div)
Forme.default_config = :mine

module KaeruEra
  class App < Sinatra::Base
    KE = Recorder.new(DB, 'kaeruera', 'kaeruera')
    PER_PAGE = 25

    set :environment, 'production'
    disable :run
    use Rack::Session::Cookie, :secret=>File.file?('kaeruera.secret') ? File.read('kaeruera.secret') : (ENV['KAERUERA_SECRET'] || SecureRandom.hex(20))
    use Rack::Csrf, :skip => ['POST:/report_error']
    helpers Forme::Sinatra::ERB

    def h(text)
      Rack::Utils.escape_html(text)
    end

    def url_escape(text)
      Rack::Utils.escape(text)
    end

    def user_apps
      Application.with_user(session[:user_id])
    end

    def get_application
      @app = Application.first!(:user_id=>session[:user_id], :id=>params[:application_id].to_i)
    end

    def get_error
      @error = Error.with_user(session[:user_id]).first!(:id=>params[:id].to_i)
    end

    def paginator(dataset, per_page=PER_PAGE)
      page = (params[:page] || 1).to_i
      page = 1 if page < 1
      @previous_page = true if page > 1
      @page = page
      values = dataset.limit(per_page+1, (page - 1) * per_page).all
      if values.length == per_page+1
        values.pop
        @next_page = true
      end
      values
    end
    def modify_page(i)
      query = env['QUERY_STRING']
      found_page = false
      if query && !query.empty?
        query = query.sub(/page=(\d+)\z/) do
          found_page = true
          "page=#{$1.to_i+i}"
        end 
        if found_page == false && i == 1
          query += "&page=2"
        end
      elsif i == 1
        query = "page=2"
      end

      "#{env['PATH_INFO']}?#{query}"
    end
    def previous_page
      return unless @previous_page
      "<a class='btn' href=\"#{modify_page(-1)}\">Previous Page</a>"
    end
    def next_page
      return unless @next_page
      "<a class='btn' href=\"#{modify_page(1)}\">Next Page</a>"
    end

    before do
      unless %w'/application.css /favicon.ico /login /logout /report_error'.include?(env['PATH_INFO'])
        redirect('/login', 303) if !session[:user_id]
      end
    end

    error do
      KE.record(:params=>params, :env=>env, :session=>session, :error=>request.env['sinatra.error'])
      erb("Sorry, an error occurred")
    end

    get '/login' do
      render :erb, :login
    end
    post '/login' do
      if i = User.login_user_id(params[:email].to_s, params[:password].to_s)
        session[:user_id] = i
        redirect('/', 303)
      else
        redirect('/login', 303)
      end
    end
    
    post '/logout' do
      session.clear
      redirect '/login'
    end

    get '/change_password' do
      erb :change_password
    end
    post '/change_password' do
      user = User.with_pk!(session[:user_id])
      user.password = params[:password].to_s
      user.save
      redirect('/', 303)
    end

    get '/add_application' do
      erb :add_application
    end
    post '/add_application' do
      Application.create(:user_id=>session[:user_id], :name=>params[:name])
      redirect('/', 303)
    end

    get '/' do
      @apps = user_apps.order(:name).all
      erb :applications
    end

    get '/applications/:application_id/reporter_info' do
      get_application
      erb :reporter_info
    end
    get '/applications/:application_id' do
      get_application
      @errors = paginator(@app.app_errors_dataset.most_recent)
      erb :errors
    end
    get '/error/:id' do
      @error = get_error
      erb :error
    end
    post '/update_error/:id' do
      @error = get_error
      halt(403, erb("Error Not Open")) if @error.closed
      @error.closed = true if params[:close] == '1'
      @error.update(:notes=>params[:notes].to_s)
      redirect("/error/#{@error.id}")
    end

    get '/search' do
      if search = params[:search]
        @errors = paginator(Error.search(params, session[:user_id]).most_recent)
        erb :errors
      else
        @apps = user_apps.order(:name).all
        erb :search
      end
    end

    post '/report_error' do
      params = JSON.parse(request.body.read)
      data = params['data']
      app_id = Application.first!(:token=>params['token'].to_s, :id=>params['id'].to_i).id

      h = {
        :application_id=>app_id,
        :error_class=>data['error_class'],
        :message=>data['message'],
        :backtrace=>Sequel.pg_array(data['backtrace'])
      }

      if v = data['params']
        h[:params] = Sequel.pg_json(v)
      end
      if v = data['session']
        h['session'] = Sequel.pg_json(v)
      end
      if v = data['env']
        h[:env] = Sequel.hstore(v)
      end

      error_id = DB[:errors].insert(h)
      "{\"error_id\": #{error_id}}"
    end
  end
end
