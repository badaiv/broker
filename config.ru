$root_path = File.expand_path(File.dirname(__FILE__)) + '/'
require $root_path + './lib/broker.rb'
require 'dotenv'

# set ENVIRONMENT in your env vars
abort("Set up ENVIRONMENT variable to 'dev' or 'prod' ") if ENV['ENVIRONMENT'].nil?
Dotenv.load( $root_path + "config/.env.#{ENV['ENVIRONMENT']}")

# ENV['LOGGER'].nil? ? (logger  = Logger.new(STDOUT)) : (logger  = Logger.new($root_path + ENV['LOGGER']))
# use Rack::CommonLogger, logger

run Broker::API