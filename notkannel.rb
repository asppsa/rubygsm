#!/usr/bin/env ruby
# vim: noet

require "rubygsm"
require "rubygems"
require "net/http"
require "rack"


module NotKannel
	def self.time(dt=nil)
		dt = DateTime.now unless dt
		#dt.strftime("%I:%M%p, %d/%m")
		dt.strftime("%I:%M%p")
	end

	# incoming sms are http GETted to
	# localhost, where an app should be
	# waiting to do something interesting
	class Receiver
		def incomming from, dt, msg
			time = NotKannel::time(dt)
			puts "[IN]  #{time} <- #{from}: #{msg}"
			
			begin
				msg = Rack::Utils.escape(msg)
				from = Rack::Utils.escape(from)
				url = "/?sender=#{from}&message=#{msg}"
				Net::HTTP.get "localhost", url, 4500
			
			# it's okay if the request failed, # but log it anyway. todo: should we
			# automatically retry here?
			rescue Errno::ECONNREFUSED: get_failed url, "No application was listening"
			rescue Timeout::Error:      get_failed url, "The connection timed out"
			end
		end
		
		def get_failed url, msg
			puts "----"
			puts "  Couldn't GET: http://localhost/#{url}"
			puts "  #{msg}"
			puts "  Discarding incoming SMS"
			puts "----"
		end
	end

	# outgoing sms are send from the app
	# to us (as if we were kannel), and
	# pushed to the modem
	class Sender
		def call(env)
			req = Rack::Request.new(env)
			res = Rack::Response.new
			catch :done do
		
				# required parameters (the
				# others are just ignored)
				to = req.GET["to"]
				txt = req.GET["text"]
			
				unless to and txt
					res.write "MISSING PARAMS"
					throw :done
				end
				
				# write to screen log
				time = NotKannel::time
				puts "[OUT] #{time} -> #{to}: #{txt}"

		
				# no modem is present (we're
				# probably running offline)
				if $mc.nil?
					res.write "ERROR"
					puts "----"
					puts "  Couldn't send (no modem)"
					puts "  Discarding outgoing SMS"
					puts "----"
					throw :done
				end
		
				begin
					# (attempt to) send the sms
					# via the modem commander, and
					# respond as kannel would
					$mc.send to, txt
					res.write "0: Accepted"
		
				# couldn't send the message
				rescue Modem::Error => err
					res.write "ERROR"
					puts "----"
					puts "  Couldnt send (#{err.desc})"
					puts "  Discarding outgoing SMS"
					puts "----"
				end
			end
			
			res.finish
		end
	end
end


begin
	# during dev, it's important to EXPLODE as
	# noisily as possible when something goes wrong
	Thread.abort_on_exception = true
	Thread.current["name"] = "main"
	
	# initialize receiver (this works
	# even if no modem is plugged in)
	port = (ARGV.length > 0) ? ARGV[0] : "/dev/ttyUSB0"
	k = NotKannel::Receiver.new
	rcv = k.method :incomming
	$mc = nil
	
	begin
		# [attempt to] initialize the modem
		puts "Initializing Modem on #{port}..."
		m = Modem.new port
		$mc = ModemCommander.new(m)
		$mc.use_pin(1234)

		# start receiving sms
		$mc.receive rcv
	
	# couldn't open modem
	rescue Errno::ENOENT
		puts "FAIL. Are you sure that your " +\
		     "modem is plugged in to #{port}?\n--"
	
	# something else went wrong
	rescue Modem::Error => err
		puts "FAIL. Couldn't initialize the modem"
		puts "RubyGSM says: #{err.desc}\n--"
	end
	
	
	# watch files in /tmp/sms, and process
	# each as if it were an incoming sms
	Thread.new do
		path = "/tmp/sms"
		puts "Watching for new messages in #{path}..."
		`mkdir #{path}` unless File.exists? path
		
		# to differentiate between injected and
		# real incoming sms in the rubygsm log
		Thread.current["name"] = "injector"

		while true
			`find #{path} -type f -print0`.split("\0").each do |file|
				if m = File.read(file).strip.match(/^(\d+):\s*(.+)$/)
					
					# pass to NotKannel::Receiver
					from, msg = *m.captures
					rcv.call from, nil, msg
					
					# delete the file, so we don't
					# process it again next time
					File.unlink(file)
				end
			end

			# re-check in
			# two seconds
			sleep 2
		end
	end


	# ...and sending!
	puts "Running NotKannel..."
	Rack::Handler::Mongrel.run(
		NotKannel::Sender.new,
		:Port=>13013)


# something went wrong during startup
rescue Modem::Error => err
	puts "\n[ERR] #{err.desc}\n"
	puts err.backtrace
end

