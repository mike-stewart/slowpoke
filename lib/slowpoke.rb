require "slowpoke/version"
require "rack-timeout"
require "robustly"
require "slowpoke/railtie"
require "action_view/template"
require "action_controller/base"
require "active_record/connection_adapters/postgresql_adapter"
require "action_dispatch/middleware/exception_wrapper"

module Slowpoke
  class << self
    attr_accessor :database_timeout
  end

  def self.timeout
    @timeout ||= (ENV["TIMEOUT"] || 15).to_i
  end

  def self.timeout=(timeout)
    @timeout = Rack::Timeout.timeout = timeout
  end
end

# remove noisy logger
Rack::Timeout.unregister_state_change_observer(:logger)

ActionDispatch::ExceptionWrapper.rescue_responses["Rack::Timeout::RequestTimeoutError"] = :service_unavailable

# hack to bubble timeout errors
class ActionView::Template

  def handle_render_error_with_timeout(view, e)
    raise e if e.is_a?(Rack::Timeout::Error)
    handle_render_error_without_timeout(view, e)
  end
  alias_method_chain :handle_render_error, :timeout

end

# notifications
class ActionController::Base

  def rescue_from_timeout(exception)
    ActiveSupport::Notifications.instrument("timeout.slowpoke", {})

    # extremely important
    # protect the process with a restart
    # https://github.com/heroku/rack-timeout/issues/39
    Process.kill "QUIT", Process.pid

    raise exception
  end
  rescue_from Rack::Timeout::Error, with: :rescue_from_timeout

end

# database timeout
class ActiveRecord::ConnectionAdapters::PostgreSQLAdapter

  def configure_connection_with_statement_timeout
    configure_connection_without_statement_timeout
    safely do
      timeout = Slowpoke.database_timeout || Slowpoke.timeout
      if ActiveRecord::Base.logger
        ActiveRecord::Base.logger.silence do
          execute("SET statement_timeout = #{timeout * 1000}")
        end
      else
        execute("SET statement_timeout = #{timeout * 1000}")
      end
    end
  end
  alias_method_chain :configure_connection, :statement_timeout

end
