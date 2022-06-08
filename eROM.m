classdef eROM < handle
%eROM   A custom class for range of motion experiments
%
%   This class should be used to collect real-time information from
%   a Qualisys TCP/IP stream and a force/torque sensor with compatible
%   DAQ. 
%
%   The purpose of this class is to provide a few simple functions to
%   access the most important data - it does not come close to the full
%   protocol features.
%
%   Usage:
%
%       r = eROM creates a new client and automatically tries to connect
%           to a locally running QTM server and DAQ.
%
%       r.initGUI opens the visual interface with Start, Stop and Save
%       buttons.
%
%
%       Settings
%           Change settings using the r.settings structure:
%           (defaults shown first)
%
%         DAQHZ: 1500       
%           DAQ load cell strain acquisition frequency
%
%         GUIHZ: 15         
%           GUI refresh frequency
%
%       maxTime: 600        
%           Max duration of recording (seconds)
%
%       figtype: 'polar' | '3d'  
%           Show torque and orientations in polar figures, or in
%           a 3d cartesian box grid (legacy). 
%
%       The following settings apply only to the polar figtype.
%
%        volume: 'both' | 'cartesian' | 'quaternion'
%           Show orientation on a cartesian sphere, on a 3-sphere
%           projection, or both simultaneously.
%
%      coverage: 'heatmap' | 'trace'
%           Track coverage through a surface heatmap, or as a trace of
%           individual points
%
%      heatmode: 'return' | 'time'
%           If coverage is 'heatmap', increase heat only when an
%           orientation is returned to or continuously over time (even when
%           dwelling in one spot).
%
%        ntrace: 10000
%           If coverage is 'trace', max number of trace points to render
%
%       nsphere: 100
%           The spatial resolution of the sphere. Large numbers will
%           increase fidelity of the heatmap but also render time.
%
%       
%           
%
%   More help text and features in future versions
%
%   2018 Enrico Eberhard
    
    properties (Access = public)
        h
        strains = struct('data',zeros(0,6),'time',[]);
        states = [];
        metadata = struct('individual', '', ...
                          'preservation', '', ...
                          'limb', '', ...
                          'joint', '');
        settings = struct('DAQHZ', 1500, ...
                          'GUIHZ', 10, ...
                          'maxTime', 600, ...
                          'recording',true,...
                          'figtype', 'polar',...
                          'volume', 'both',...
                          'coverage', 'heatmap',...
                          'heatmode','return',...
                          'ntrace',10000,...
                          'nsphere', 100,...
                          'nreturn', 5, ...
                          'jointcenter', [35 0 68],...
                          'twarn', 5,...
                          'tonemode', 'axes');
       end
    properties (Access = protected)
        t
        d
        s
        subtrial = 1
        sequence
        mat = [-0.0220   -0.0424   -1.9110   -0.1860   10.7572    0.2788;
                0.1268   -2.1926   -0.0108  -13.7886    3.6648   -5.9668;
               -0.0952   -0.0172   -1.9252  -10.4546   -7.0886    0.5810;
                1.8094    1.3498    0.2202    6.4598  -12.4818   -8.3698;
                0.0448   -0.0226   -1.9438   10.7210   -8.0908    0.1228;
               -1.9830    0.8410   -0.0460    7.6644    8.4408   -9.5170];
        offset = zeros(1,6);
    end
    methods  (Access = public)
        function obj = eROM(port, vendor)
            %eQMC Constructor
            %
            %   Creates a new eROM object and tries to connect
            %   to a local QTM TCP/IP server and attached DAQ
            
            if ~exist('port','var')
                port = 22224;
            end
            
            if ~exist('vendor','var')
                vendor = 'NI';
            end
            
            %connect to QTM tcpip stream
            try
                obj = connectQTM(obj,port);
            catch e
                fprintf(2,'%s\nCheck QTM real-time server is running and run the connectQTM function\n',...
                    e.message);
            end
            
            try
                obj = connectDAQ(obj,vendor);
            catch e
                fprintf(2,'%s\nCheck valid DAQ is connected and run the connectDAQ function\n',...
                    e.message);
            end
            
        end
        
        function obj = connectQTM(obj,port)
            %connectQTM
            %
            %   Attempts to connect to a local QTM TCP/IP server
            
            if ~exist('port','var')
                port = 22224;
            end
            
            obj.t = tcpip('localhost', port);
            
            obj.t.TransferDelay = 'off';
            obj.t.InputBufferSize = 32768;
            obj.t.OutputBufferSize = 32768;
            
            obj.t.BytesAvailableFcnMode = 'byte';
            %expected data frame length
            obj.t.BytesAvailableFcnCount = 164;
            
            fopen(obj.t);
            obj.waitReply;
            obj.printread;
            
            obj.writeCommand('version 1.13');
            obj.waitReply;
            obj.printread;
            
            
            obj.QTMCaptureTime(obj.settings.maxTime);
        end
        
        function disconnectQTM(obj)
            %disconnectQTM
            %
            %   Deletes the connection to QTM TCP/IP server
            delete(obj.t)
        end
        
        
        function obj = connectDAQ(obj, vendor)
            %connectDAQ
            %
            %   Connects to a DAQ
            
            if ~exist('vendor','var')
                vendor = 'NI';
            end
            
            obj.d = daq.getDevices;
            obj.s = daq.createSession(vendor);
            %ch = obj.d.Subsystems(1).ChannelNames;
            addAnalogInputChannel(obj.s, obj.d.ID, 0:5, 'Voltage');
            
        end

        function frame = getFrame(obj)
            %getFrame
            %
            %   Returns a dataframe from QTM
            obj.flush;
            obj.writeCommand('GetCurrentFrame 3D 6D');
            
            %read first 8 bytes (size | data type)
            frame.size = fread(obj.t, 1, 'uint32');
            frame.type = fread(obj.t, 1, 'uint32');
            
            if(frame.type ~= 3)
                obj.flush
                return
            end
            
            frame.qtime = fread(obj.t, 2, 'uint32');
            frame.qtime = typecast(uint32([frame.qtime(2), frame.qtime(1)]), 'uint64');
            frame.time = now;
            frame.num = fread(obj.t, 1, 'uint32');
            frame.count = fread(obj.t, 1, 'uint32');
            
            for c = 1:frame.count
                cmp.size = fread(obj.t, 1, 'uint32');
                cmp.type = fread(obj.t, 1, 'uint32');
                
                switch(cmp.type) 
                    case 1  %3D data
                        cmp.nmarker = fread(obj.t, 1, 'uint32');
                        cmp.drop2d = fread(obj.t, 1, 'uint16');
                        cmp.sync2d = fread(obj.t, 1, 'uint16');

                        for b = 1:cmp.nmarker
                            marker.X = fread(obj.t, 1, 'float32');
                            marker.Y = fread(obj.t, 1, 'float32');
                            marker.Z = fread(obj.t, 1, 'float32');

                            cmp.marker(b) = marker;
                        end

                        frame.d3D = cmp;
                        
                    case 5 %6D data
                        cmp.nbody = fread(obj.t, 1, 'uint32');
                        cmp.drop2d = fread(obj.t, 1, 'uint16');
                        cmp.sync2d = fread(obj.t, 1, 'uint16');

                        for b = 1:cmp.nbody
                            body.X = fread(obj.t, 1, 'float32');
                            body.Y = fread(obj.t, 1, 'float32');
                            body.Z = fread(obj.t, 1, 'float32');
                            body.R = fread(obj.t, 9, 'float32');

                            body.R = reshape(body.R,3,3)';

                            cmp.body(b) = body;
                        end

                        frame.d6D = cmp;
                        
                end
                
            end
            
        end
        
        function state = getState(obj)
            %getState
            %
            %   Returns an eventframe from QTM
            
            state.type = 0; tries = 0;
            while(state.type ~= 6)
                obj.flush;
                obj.writeCommand('GetState');

                %read first 8 bytes (size | data type)
                state.size = fread(obj.t, 1, 'uint32');
                state.type = fread(obj.t, 1, 'uint32');
                
                if tries > 5
                    return 
                end
                tries = tries + 1;
            end
            
            state.ID = fread(obj.t, 1, 'uint8');
            
            switch(state.ID)
                case 1
                    state.event = 'Connected';
                case 2
                    state.event = 'Connection Closed';
                case 3
                    state.event = 'Capture Started';
                case 4
                    state.event = 'Capture Stopped';
                case 6
                    state.event = 'Calibration Started';
                case 7
                    state.event = 'Calibration Stopped';
                case 8
                    state.event = 'RT From File Started';
                case 9
                    state.event = 'RT From File Stopped';
                case 10
                    state.event = 'Waiting For Trigger';
                case 11
                    state.event = 'Camera Settings Changed';
                case 12
                    state.event = 'QTM Shutting Down';
                case 13
                    state.event = 'Capture Saved';
            end
            
        end
        
        function writeCommand(obj, cmd)
            cmdint8 = uint8(cmd);
            size = typecast(swapbytes(uint32(length(cmdint8) + 8)), 'uint8');
            type = typecast(swapbytes(uint32(1)), 'uint8');
            data = [size type cmdint8];

            fwrite(obj.t, data)
        end
        
        function writeXML(obj, xml)
            obj.QTMControl(true);
            xmlint8 = uint8(xml);
            size = typecast(swapbytes(uint32(length(xmlint8) + 8)), 'uint8');
            type = typecast(swapbytes(uint32(2)), 'uint8');
            data = [size type xmlint8];

            fwrite(obj.t, data);
            obj.QTMControl(false)
        end
        
        function waitReply(obj)
            while ~obj.t.BytesAvailable
            end
        end
        
        function QTMCaptureTime(obj,time)
            if ~exist('time','var')
                time = 600;
            end
            obj.writeXML(['<QTM_Settings><General><Capture_Time>',...
                sprintf('%f',time), ...
                '</Capture_Time></General></QTM_Settings>']);
        end
        
        function QTMReset(obj)
            obj.QTMControl(true);
            
            openednew = false;
            
            state = obj.getState;
            while state.ID ~= 1
                switch(state.ID)
                    case 2
                        if ~openednew
                            obj.writeCommand('New');
                            obj.waitReply;
                            openednew = true;
                        end
                    case 3
                        obj.writeCommand('Stop');
                        obj.waitReply;
                    case 4
                        obj.writeCommand('Close');
                        obj.waitReply;
                end
                state = obj.getState;
            end
            obj.QTMControl(false);
        end
        function QTMStart(obj)
            obj.QTMControl(true);
            
            state = obj.getState;
            while state.ID ~= 3
                switch(state.ID)
                    case 1
                        obj.writeCommand('Start');
                        obj.waitReply;
                    otherwise
                        obj.QTMReset;
                        obj.QTMControl(true);
                end
                state = obj.getState;
            end
                
            obj.QTMControl(false);
        end
        function QTMStop(obj)
            obj.QTMControl(true);
            
            state = obj.getState;
            while state.ID == 3
                obj.writeCommand('Stop');
                obj.waitReply;
                state = obj.getState;
            end
                
            obj.QTMControl(false);
        end
        function QTMSave(obj, filename)
            obj.QTMControl(true);
            
            state = obj.getState;
            if state.ID == 4
                obj.writeCommand(sprintf('Save %s', filename));
                obj.waitReply;
                obj.printread;
            end
            obj.QTMControl(false);
        end
        
        function QTMControl(obj, ctrl)
            obj.flush;
            if ctrl
                obj.writeCommand('TakeControl');
            else
                obj.writeCommand('ReleaseControl');
            end
            obj.waitReply;
            obj.flush;
        end
        
        function printread(obj)
            if obj.t.BytesAvailable > 8
                reply = char(fread(obj.t, obj.t.BytesAvailable)');
                fprintf('%s\n', reply(9:end));
            end
            while obj.t.BytesAvailable 
                fprintf('%s\n', char(fread(obj.t, obj.t.BytesAvailable)'));
            end 
        end
        
        function flush(obj)
            if obj.t.BytesAvailable 
                fread(obj.t, obj.t.BytesAvailable);
            end
        end
        
        
        function offset = zeroDAQ(obj, duration, rate)
            
            if ~exist('duration', 'var')
                duration = 0.2;
            end
            if ~exist('rate', 'var')
                rate = 1000;
            end
            
            obj.s.DurationInSeconds = duration;
            obj.s.Rate = rate;
            
            obj.stop();
            %suppress warnings about 
            ws = warning;
            warning('off','all');
            data = obj.s.startForeground();
            warning(ws);
     
            offset = mean(data);
            obj.offset = offset;
            
        end
        
        
        function startBackground(obj,duration,DAQrate,QTMrate)
            obj.stop();
            %obj.clear();
            
            notifywhen = round(DAQrate / QTMrate);
            obj.s.DurationInSeconds = duration;
            obj.s.Rate = DAQrate;
            obj.s.NotifyWhenDataAvailableExceeds = notifywhen;
            
            obj.h.lh = obj.s.addlistener('DataAvailable',...
                @(src,event)eROM.dataAvailableCallback(src,event,obj));
            
            %check that there is a figure for the callback
            if ~isfield(obj.h, 'fh') || ~isvalid(obj.h.fh)
                obj.initGUI();
                return
            end
            
            obj.s.startBackground();
        end
        
        
        function stop(obj)
            obj.s.stop();
            if isfield(obj.h, 'lh') && isvalid(obj.h.lh)
                delete(obj.h.lh);
            end
        end
        
        
        function save(obj)
            %save any data to workspace
            trial = struct;
            if isstruct(obj.strains) && isfield(obj.strains, 'time') ...
                && ~isempty(obj.strains.time)
                trial.strains = obj.strains;
            end
            
            if isstruct(obj.states) && ~isempty(obj.states)
                trial.states = obj.states;
            end
            
            if isfield(trial, 'strains') || isfield(trial, 'states')
                
                trial.strains.offset = obj.offset;
                trial.strains.mat = obj.mat;
                trial.ft.time = trial.strains.time;
                trial.ft.data = ...
                    (trial.strains.offset - trial.strains.data)...
                    *trial.strains.mat;
                
%                 ts = datetime('now','Format','yyyy-MM-dd_HH-mm-ss');
%                 name = sprintf('TRIAL_%s',ts);

                name = sprintf('%s_%i_%s', ...
                                obj.makeName, obj.subtrial,...
                                obj.sequence{obj.subtrial}); 
                
                res = inputdlg({'Filename', 'Description'}, 'Save',...
                    [1 50; 5 50], {name,''});
                
                if isempty(res)
                   return 
                end
                name = res{1};
                trial.description = res{2};
                
                save(['../Data/' name '.mat'],'trial');
                assignin('base','trial',trial);
                
                obj.QTMSave([name '.qtm']);
                
                fprintf('Saved trial data to workspace and to file:\n%s\n',name);
            end
            
        end
        
        
        function clear(obj)
            %clear data from object
            obj.strains = struct('data',zeros(0,6),'time',[]);
            obj.states = [];
            
            %reset GUI
            obj.initGUI;
            obj.flush;
            
        end
        
        function fh = initGUI(obj)
            if ~isfield(obj.h, 'fh') || ~isvalid(obj.h.fh)
                obj.h.fh = figure();
            end
            fh = obj.h.fh;
            
            %set up full-screen figure
            opengl hardware; 
            figure(fh); clf(fh);
            pause(0.00001);
            warning('off','MATLAB:HandleGraphics:ObsoletedProperty:JavaFrame')
            frame_h = get(handle(fh),'JavaFrame');
            set(frame_h,'Maximized',1); 
            warning('on','MATLAB:HandleGraphics:ObsoletedProperty:JavaFrame')
            
            fh.NumberTitle = 'off';
            fh.Name = obj.makeName;
            
            %axes for putting text on figure
            ax.txt = axes(fh, 'Position',[0 0 1 1]);
            ax.txt.Visible = 'off';
            ax.txt.HitTest = 'off';
            
            txt.name = text(ax.txt, 0.1, 0.05, ...
                            strrep(obj.makeName, '_', '\_'), ...
                            'HorizontalAlignment', 'Center');
            
            txt.subtrial = text(ax.txt, 0.25, 0.05, ...
                            sprintf('Subtrial %i',obj.subtrial), ...
                            'HorizontalAlignment', 'Center');
            
            obj.getSequence;
            txt.seq = text(ax.txt, 0.4, 0.05, ...
                            sprintf('Sequence: %s',...
                            obj.sequence{obj.subtrial}), ...
                            'HorizontalAlignment', 'Center');        
                        
            if strcmp(obj.settings.figtype,'3d')
            
                %force axes
                ax.f = axes('Position',[0.0 0.45 0.5 0.5]);
                go.f = scatter3(ax.f,[],[],[]);
                axis(ax.f, 'equal');
                axis(ax.f, [-5 5 -5 5 -5 5]);
                xlabel(ax.f,'X'); ylabel(ax.f,'Y'); zlabel(ax.f,'Z');


                %torque axes
                ax.t = axes('Position',[0.5 0.45 0.5 0.5]);
                go.t = scatter3(ax.t,[],[],[]);
                axis(ax.t, 'equal');
                axis(ax.t, [-50 50 -50 50 -50 50]);
                xlabel(ax.t,'X'); ylabel(ax.t,'Y'); zlabel(ax.t,'Z');

                %marker axes
                ax.m = axes('Position',[0.25 0.05 0.5 0.5]);  

                hold(ax.m,'on');
                go.m = gobjects(1,10);
                for n = 1:numel(go.m)
                    go.m(n) = scatter3(ax.m,[],[],[]);
                end
                go.rbl = line(ax.m, [0 0], [0 0], [0 0]);
                hold(ax.m,'off')

                axis(ax.m, 'equal');
                axis(ax.m, [-200 200 -200 200 -10 390]);
                xlabel(ax.m,'X'); ylabel(ax.m,'Y'); zlabel(ax.m,'Z');
            
            else

                %torque minus force axes
                ax.tr = polaraxes('Position',[0.05 0.25 0.4 0.6]);
                go.tr = polarscatter(ax.tr,[],[]);
                hold(ax.tr, 'on')
                go.trp = polarscatter(ax.tr,0,0,'r+');
                hold(ax.tr, 'off')
                
                go.trp.SizeData = 50;
                
                ax.tr.RLim = [0 5*obj.settings.twarn];
                ax.tr.RTick = (1:5)*obj.settings.twarn;
                ax.tr.RAxisLocation = 0;
                text(ax.txt,0.25,0.95, 'Joint Torque',...
                                'HorizontalAlignment', 'Center',...
                                'FontSize', 16, 'FontWeight', 'Bold');
                
                %spherical coverage plot
                ax.sph = axes('Position',[0.55 0.05 0.4 0.9]);

                tri = struct; [tri.Vertices,tri.Faces] = spheretri(obj.settings.nsphere);
                go.sph = patch(tri);

                go.sph.EdgeColor = 'k'; go.sph.FaceColor = 'interp';
                go.sph.CDataMapping = 'direct';

                nv = length(go.sph.Vertices);
                go.sph.FaceVertexCData = zeros(nv,1);


                hold(ax.sph,'on');
                go.sphp = scatter3(ax.sph,[],[],[],'r.');
                go.sphp.SizeData = 500; go.sphp.LineWidth = 10;
                nn = NaN(obj.settings.ntrace,1);
                go.trace = scatter3(ax.sph,nn,nn,nn,'.');
                hold(ax.sph,'off');
                
                if strcmp(obj.settings.volume,'cartesian')
                    ax.sph.Title.String = 'Cartesian Coverage';
                else
                    ax.sph.Title.String = '3-Sphere Coverage'; 
                end
                
                axis(ax.sph, 'equal');
                axis(ax.sph, [-1 1 -1 1 -1 1]);
                xlabel(ax.sph,'X'); ylabel(ax.sph,'Y'); zlabel(ax.sph,'Z');
                ax.sph.Color = 'none';
                view(ax.sph,30,30);
                
                if strcmp(obj.settings.coverage,'heatmap')
                    go.trace.Visible = 'off';
                    go.sph.EdgeAlpha = 0.01; go.sph.FaceAlpha = 1;
                else
                    go.trace.Visible = 'on';
                    go.sph.EdgeAlpha = 0.1; go.sph.FaceAlpha = 0.1;
                end
               
                
                if strcmp(obj.settings.volume,'both')
                    %second spherical coverage plot
                    ax.sph.Position = [0.45 0.35 0.3 0.6];
                    ax.sph.Visible = 'off';
                    hold(ax.sph, 'on')
                    plot3(ax.sph,[-1 0],[-1 -1],[-1 -1], 'r', 'LineWidth', 2);
                    plot3(ax.sph,[-1 -1],[-1 0],[-1 -1], 'g', 'LineWidth', 2);
                    plot3(ax.sph,[-1 -1],[-1 -1],[-1 0], 'b', 'LineWidth', 2);
                    hold(ax.sph, 'off')
                    text(ax.txt,0.6,0.95, '3-Sphere Coverage',...
                                'HorizontalAlignment', 'Center',...
                                'FontSize', 16, 'FontWeight', 'Bold');
                    view(ax.sph,-60,30)
                    
                    
                    ax.sph2 = axes('Position',[0.7 0.05 0.3 0.6]);

                    tri = struct; [tri.Vertices,tri.Faces] = spheretri(obj.settings.nsphere);
                    go.sph2 = patch(tri);

                    go.sph2.EdgeColor = 'k'; go.sph2.FaceColor = 'interp';
                    go.sph2.CDataMapping = 'direct';

                    nv = length(go.sph2.Vertices);
                    go.sph2.FaceVertexCData = zeros(nv,1);


                    hold(ax.sph2,'on');
                    go.sphp2 = scatter3(ax.sph2,[],[],[],'r.');
                    go.sphp2.SizeData = 500; go.sphp2.LineWidth = 10;
                    nn = NaN(obj.settings.ntrace,1);
                    go.trace2 = scatter3(ax.sph2,nn,nn,nn,'.');
                    hold(ax.sph2,'off');
                    text(ax.txt,0.85,0.65, 'Cartesian Coverage',...
                                'HorizontalAlignment', 'Center',...
                                'FontSize', 16, 'FontWeight', 'Bold');
                    axis(ax.sph2, 'equal');
                    axis(ax.sph2, [-1 1 -1 1 -1 1]);
                    ax.sph2.Color = 'none';
                    
                    
                    ax.sph2.Visible = 'off';
                    hold(ax.sph2, 'on')
                    plot3(ax.sph2,[-1 0],[-1 -1],[-1 -1], 'r', 'LineWidth', 2);
                    plot3(ax.sph2,[-1 -1],[-1 0],[-1 -1], 'g', 'LineWidth', 2);
                    plot3(ax.sph2,[-1 -1],[-1 -1],[-1 0], 'b', 'LineWidth', 2);
                    hold(ax.sph2, 'off')

                    view(ax.sph2,30,30)
                    
                    if strcmp(obj.settings.coverage,'heatmap')
                        go.trace2.Visible = 'off';
                        go.sph2.EdgeAlpha = 0.01; go.sph2.FaceAlpha = 1;
                    else
                        go.trace2.Visible = 'on';
                        go.sph2.EdgeAlpha = 0.1; go.sph2.FaceAlpha = 0.1;
                    end
                end
                
                
                
                
                %buttons
                bt.start = uicontrol(fh);
                bt.start.Style = 'togglebutton';
                bt.start.Units = 'Normalized';
                bt.start.Position = [0.05 0.1 0.1 0.05];
                obj.s = struct('IsRunning',false)
                if obj.s.IsRunning
                    bt.start.String = 'Stop';
                    bt.start.Value = 1;
                else
                    bt.start.String = 'Start';
                end
                bt.start.Callback = {@eROM.startButtonCallback, obj};
                
                bt.save = uicontrol(fh);
                bt.save.Units = 'Normalized';
                bt.save.Position = [0.2 0.1 0.1 0.05];
                bt.save.String = 'Save';
                bt.save.Callback = {@eROM.saveButtonCallback, obj};
                bt.save.Enable = 'off';
                
                bt.zero = uicontrol(fh);
                bt.zero.Units = 'Normalized';
                bt.zero.Position = [0.35 0.1 0.1 0.05];
                bt.zero.String = 'Zero DAQ';
                bt.zero.Callback = {@eROM.zeroButtonCallback, obj};
                
                bt.reset = uicontrol(fh);
                bt.reset.Units = 'Normalized';
                bt.reset.Position = [0.85 0.9 0.1 0.05];
                bt.reset.String = 'Reset';
                bt.reset.Callback = {@eROM.resetButtonCallback, obj};
                bt.reset.BackgroundColor = 'r';
                bt.reset.ForegroundColor = 'k';
                
                
                bt.prev = uicontrol(fh);
                bt.prev.Units = 'Normalized';
                bt.prev.Position = [0.5 0.025 0.05 0.05];
                bt.prev.String = 'Prev';
                bt.prev.Callback = {@eROM.seqButtonCallback, obj, 'prev'};
                
                bt.next = uicontrol(fh);
                bt.next.Units = 'Normalized';
                bt.next.Position = [0.6 0.025 0.05 0.05];
                bt.next.String = 'Next';
                bt.next.Callback = {@eROM.seqButtonCallback, obj, 'next'};
                
                
                obj.h.bt = bt;
            end
            
            
            %make a sound object
            duration = 0.1;
            fs = 8192;
            dt = 1/fs; % seconds per sample (1/fs)
            tm = (0:dt:duration)'; % seconds 
            
            %chord = [440 660 990 1485 2227.5];
            chord = [440 554.4 660 830.6 990];
            
            freq = chord(1); 
            y = sin(2*pi*freq*tm);
            obj.h.ad = audioplayer(y, 8192);
            freq = chord(2); 
            y = 0.9*sin(2*pi*freq*tm);
            obj.h.ad(2) = audioplayer(y, 8192);
            freq = chord(3); 
            y = 0.8*sin(2*pi*freq*tm);
            obj.h.ad(3) = audioplayer(y, 8192);
            freq = chord(4); 
            y = 0.7*sin(2*pi*freq*tm);
            obj.h.ad(4) = audioplayer(y, 8192);
            freq = chord(5); 
            y = 0.6*sin(2*pi*freq*tm);
            obj.h.ad(5) = audioplayer(y, 8192);
            
            obj.h.fh = fh;
            obj.h.ax = ax;
            obj.h.go = go;
            obj.h.txt = txt;
            
            
            
            
        end
        
        function name = makeName(obj, assign)
            
            name = '';
            if ~exist('assign', 'var')
                assign = false;
            end
            fn = fieldnames(obj.metadata);
            content = cell(size(fn));
            
            %check if any assignment is needed (empty fields)
            for n = 1:length(fn)
                assign = or(assign,isempty(obj.metadata.(fn{n})));
                content{n} = obj.metadata.(fn{n});
            end
            
            %prompt data entry
            if assign
                res = inputdlg({'Individual', 'Preservation',...
                                'Limb', 'Joint'},...
                                '',...
                                [1 20],...
                                content);
                
                if ~isempty(res)
                    %put results in metadata structure
                    for n = 1:length(fn)
                        obj.metadata.(fn{n}) = res{n};
                    end
                end
            end
            
            for n = 1:length(fn)
                name = [name obj.metadata.(fn{n}) '_']; %#ok<AGROW>
            end
            name = name(1:end-1);
        end
        
        function sequence = makeSequence(obj)
            %MAKESEQUENCE
            %
            %   Generates a new random sequence of 
            %   3 independent and 6 convoluted axes.
            
            AXES = 'FAL';

            subtrials = perms(1:3);
            subtrials = subtrials(randperm(6),:);

            s13 = AXES(randperm(3))';
            s49 = AXES(subtrials);
            sequence = cell(9,1);

            for sn = 1:3
                sequence{sn} = s13(sn);
            end

            for sn = 4:9
                sequence{sn} = s49(sn-3,:);
            end
            
            obj.sequence = sequence;
        end
        
        function sequence = getSequence(obj)
            %GETSEQUENCE            
            %
            %   Retrieves the random sequence of 
            %   3 independent and 6 convoluted axes, or
            %   calls makeSequence if none exists.
            
            if isempty(obj.sequence) || ...
                    numel(obj.sequence) ~= 9
                obj.makeSequence;
            end
            
            sequence = obj.sequence;
            
        end
        
        function updateFigText(obj)
            txt = obj.h.txt;
            
            txt.name.String = strrep(obj.makeName, '_', '\_');
            
            txt.subtrial.String = ...
                sprintf('Subtrial %i',obj.subtrial);
            
            obj.getSequence;
            txt.seq.String = sprintf('Sequence: %s',...
                            obj.sequence{obj.subtrial});  
            
        end
    end
    
    methods (Static = true)
        function dataAvailableCallback(~, event, obj)
            
            persistent lastVertex;
            
            %check that the figure has not been closed
            if ~isfield(obj.h, 'fh') || ~isvalid(obj.h.fh)
                warning('Figure deleted - stopping background acquisition');
                obj.stop;
                return
            end
            
            %save the current strain samples
            if obj.settings.recording
                obj.strains.data = [obj.strains.data; event.Data];
                obj.strains.time = [obj.strains.time; event.TimeStamps];
            end
            
            %average the current strain samples
            ud = obj.offset - mean(event.Data);
            
            %convert to force
            ft = ud*obj.mat;

            d = obj.settings.jointcenter;
            tv = ft(4:6) - cross(d, ft(1:3));
            
            if strcmp(obj.settings.tonemode,'magnitude')
                mag = norm(tv);
                RTick = obj.h.ax.tr.RTick;

                if mag > RTick(1)
                    play(obj.h.ad(1))
                    if mag > RTick(2)
                        play(obj.h.ad(2))
                        if mag > RTick(3)
                            play(obj.h.ad(3))
                            if mag > RTick(4)
                                play(obj.h.ad(4))
                                if mag > RTick(5)
                                    play(obj.h.ad(5))
                                end
                            end
                        end
                    end
                end
            else
                RTick = obj.h.ax.tr.RTick;
                abst = abs(tv);
                if any(abst > RTick(1))
                    play(obj.h.ad(1))
                    if any(abst > RTick(2))
                        play(obj.h.ad(2))
                        if any(abst > RTick(3))
                            play(obj.h.ad(3))
                            if any(abst > RTick(4))
                                play(obj.h.ad(4))
                                if any(abst > RTick(5))
                                    play(obj.h.ad(5))
                                end
                            end
                        end
                    end
                end
                
            end
            
            if strcmp(obj.settings.figtype,'3d')
                
                %update force on plot
                f = obj.h.go.f;
                f.XData = ft(1);
                f.YData = ft(2);
                f.ZData = ft(3);

                %update torque on plot
                t = obj.h.go.t;
                t.XData = ft(4);
                t.YData = ft(5);
                t.ZData = ft(6);
            
            else
            
                %calculate compensated torque
%                 d = obj.settings.jointcenter;
%                 tv = ft(4:6) - cross(d, ft(1:3));
%                 
%                 tv = ft(4:6);
                
                %update compensated torque on plot
                tr = obj.h.go.tr; trp = obj.h.go.trp;
                
                tr.ThetaData = atan2(tv(2),tv(1));
                tr.RData = norm(tv);

                trp.ThetaData = tr.ThetaData;
                trp.RData = tr.RData;

                if abs(tv(3)) < 0.1
                    tr.SizeData = 5;
                else
                    tr.SizeData = abs(tv(3))*50;
                end

                if tv(3) > 0
                    tr.MarkerFaceColor = 'flat';
                else
                    tr.MarkerFaceColor = 'none';
                end
            
            end
            
            %get the current qualisys frame
            fr = obj.getFrame();
            
            %check that 3d and 6d info is returned
            if ~isfield(fr, 'd3D') || ~isfield(fr, 'd6D')
                %warning('No 3D or 6D data from QTM (is the real-time server running?) - stopping background acquisition');
                %obj.stop;
                return
            end
            %add DAQ relative timestamp
            fr.dtime = event.TimeStamps(end);
            
            %save the frame
            if obj.settings.recording
                if isempty(obj.states)
                    obj.states = fr;
                else
                    obj.states(end+1) = fr;
                end
            end
            
            if strcmp(obj.settings.figtype,'3d')
                
                %get graphics handles
                m = obj.h.go.m;
                rbl = obj.h.go.rbl;

                [m.XData,m.YData,m.ZData] = deal([]);

                %show all visible markers
                for n = 1:fr.d3D.nmarker
                    m(n).XData = fr.d3D.marker(n).X;
                    m(n).YData = fr.d3D.marker(n).Y;
                    m(n).ZData = fr.d3D.marker(n).Z;
                end

                %overlay rigid body
                if fr.d6D.nbody
                    O(1) = fr.d6D.body(1).X;
                    O(2) = fr.d6D.body(1).Y;
                    O(3) = fr.d6D.body(1).Z;
                    A = O + [0 0 100]*fr.d6D.body(1).R;

                    rbl.XData = [O(1) A(1)];
                    rbl.YData = [O(2) A(2)];
                    rbl.ZData = [O(3) A(3)];
                end
            
            else
            
                for ii = 1:2
                    
                    if ii == 1
                        sph = obj.h.go.sph;
                        sphp = obj.h.go.sphp;
                        trace = obj.h.go.trace;
                    else
                        sph = obj.h.go.sph2;
                        sphp = obj.h.go.sphp2;
                        trace = obj.h.go.trace2;
                    end

                    %get the orientation
                    if fr.d6D.nbody

                        %cartesian mode
                        if strcmp(obj.settings.volume,'cartesian') || ii == 2
                            P = [0 0 1]*fr.d6D.body(1).R;

                        else %quaternion 3-sphere mode
                            try
                                q = quatFromRot(fr.d6D.body(1).R);
                                P = q(2:4) ./ norm(q(2:4));
                            catch
                                return
                            end
                        end

                        sphp.XData = P(1);
                        sphp.YData = P(2);
                        sphp.ZData = P(3);


                        if strcmp(obj.settings.coverage,'heatmap')

                            %find closest vertex to P
                            I = dsearchn(sph.Vertices, P);

                            if numel(lastVertex) < 2
                                lastVertex(ii) = I;
                            end
                            
                            nc = length(obj.h.fh.Colormap);
                            if sph.FaceVertexCData(I) < nc

                                if strcmp(obj.settings.heatmode, 'time')
                                    sph.FaceVertexCData(I) = sph.FaceVertexCData(I) + 2;
                                else
                                    if I ~= lastVertex(ii)
                                        sph.FaceVertexCData(I) = sph.FaceVertexCData(I) + ...
                                                                    nc / obj.settings.nreturn;
                                        lastVertex(ii) = I;
                                    end

                                end
                            end

                        else
                            %shift
                            trace.XData(1:end-1) = trace.XData(2:end);
                            trace.YData(1:end-1) = trace.YData(2:end);
                            trace.ZData(1:end-1) = trace.ZData(2:end);

                            %set
                            trace.XData(end) = P(1);
                            trace.YData(end) = P(2);
                            trace.ZData(end) = P(3);
                        end
                    end

                    if ~strcmp(obj.settings.volume, 'both')
                        continue
                    end
                end
                
            end
            
        end
        
        
        function startButtonCallback(src, ~, obj)
            
            if src.Value
                obj.QTMStart();
                obj.startBackground(obj.settings.maxTime,...
                                    obj.settings.DAQHZ,...
                                    obj.settings.GUIHZ);
                obj.h.bt.save.Enable = 'off';
                obj.h.bt.zero.Enable = 'off';
                obj.h.bt.prev.Enable = 'off';
                obj.h.bt.next.Enable = 'off';
                src.String = 'Stop';
            else
                obj.stop();
                obj.QTMStop();
                obj.h.bt.save.Enable = 'on';
                obj.h.bt.zero.Enable = 'on';
                obj.h.bt.prev.Enable = 'on';
                obj.h.bt.next.Enable = 'on';
                src.String = 'Start';
            end
        end
        
        function saveButtonCallback(~, ~, obj)
            obj.save();
        end
        
        function resetButtonCallback(~, ~, obj)
            obj.stop();
            obj.QTMStop();
            obj.QTMReset();
            obj.clear();
        end
        
        function zeroButtonCallback(~, ~, obj)
            obj.zeroDAQ();
        end
        
        
        function seqButtonCallback(~, ~, obj, type)
            
            switch(type)
                case 'prev'
                    if obj.subtrial > 1
                        obj.subtrial = obj.subtrial - 1;
                    end
                case 'next'
                    if obj.subtrial < 9
                        obj.subtrial = obj.subtrial + 1;
                    end
            end
            
            switch(obj.subtrial)
                case 4
                    obj.settings.twarn = 2;
                case 5
                    obj.settings.twarn = 4;
                case 6
                    obj.settings.twarn = 6;
                case 7
                    obj.settings.twarn = 8;
                case 8
                    obj.settings.twarn = 10;
                case 9
                    obj.settings.twarn = 12;
                otherwise
                    obj.settings.twarn = 2;
            end
            
            obj.h.ax.tr.RLim = [0 5*obj.settings.twarn];
            obj.h.ax.tr.RTick = (1:5)*obj.settings.twarn;
            
            obj.updateFigText;
        end
        
    end
end

