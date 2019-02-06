require 'rails/version'

module Griddler
  module AmazonS3SES
    class Railtie < Rails::Railtie
      if Rails::VERSION::MAJOR < 5
        middleware = ActionDispatch::ParamsParser
      else
        middleware = Rack::Head
      end

      initializer "griddler_s3_ses.configure_rails_initialization" do |app|
        Rails.application.middleware.insert_before middleware, Griddler::AmazonS3SES::Middleware
      end
    end
  end
end
