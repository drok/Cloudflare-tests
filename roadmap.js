(function() {

  var refresh = function(filter, topPadding) {
    if (this.tasks.length > 0) {
      this.node.style.minHeight = this.node.clientHeight + "px";
      this.node.innerHTML = "";
      if (filter) {
        topPadding = topPadding < 150 ? 0 : topPadding - 150;
        this.node.innerHTML = "<a style='margin: 5px; margin-top: " + topPadding + "px; display: inline-block; float: right; border-radius: 3px; color: #fff; font-size: 12px; background: #999; padding: 6px 20px 6px 20px; text-decoration: none;' href='javascript:null'>&larr; Back to the full roadmap</a>";
        var currentInstance = this;
        this.node.getElementsByTagName("A")[0].onclick = function() {
          refresh.apply(currentInstance);
        };
      }

      var options = {};
      if (this.graphOption.type !== "people") {
        options = draw.apply(this, [this.tasks.filter(function (task) {
          if (filter && task.group !== filter) {
            return false;
          } else {
            return true;
          }
        }), {}]);
      }

      if (this.graphOption.type !== "tasks") {
        if (this.people.length > 0) {
          this.people.sort(function (a, b) {
            if (a.order !== b.order) {
              return a.order > b.order ? 1 : -1;
            }
            return a.group > b.group ? 1 : -1;
          });
          draw.apply(this, [this.people.filter(function (person) {
            if (filter && person.taskGroup !== filter) {
              return false;
            } else {
              return true;
            }
          }), options]);
        }
      }
    }
  };

  var parse = function() {
    // Tasks
    var colors = d3.scale.category20();

    // For d3
    var dateFormat = d3.time.format("%Y-%m-%d");

    d3.selectAll("div.roadmap").each(function() {
      var currentInstance = {
        tasks: [],
        people: [],
        graphOption: {
          type: this.getAttribute("data-graph-type"),
          dateFormat:this.getAttribute("data-graph-date-format"),
          ticksType: this.getAttribute('data-graph-ticks'),
          webFrames: this.getAttribute('data-webframes')?.split(' '),
          additionalXAxis: this.getAttribute('data-graph-additional-xaxis') === "true"
        },
        node: this
      };
      try {
        _parseFromJsonFormat(currentInstance, JSON.parse(this.textContent || this.innerHTML), colors, dateFormat);
      } catch (error) {
        _parseFromOriginalFormat(currentInstance, colors, dateFormat);
      }
    });
  };

  var getPersonById = function (id, people) {
    for (var i = 0; i < people.length; i++) {
      if (people[i].id === id) {
        return people[i];
      }
    }
  };

  var _parseFromJsonFormat = function (currentInstance, data, colors, dateFormat) {
    var currentTask = {};
    var tasks = data.tasks;
    var people = data.people;

    var person;
    for (var i = 0; i < tasks.length; i++) {
      currentTask.type = "task";
      currentTask.group = tasks[i].taskName;
      currentTask.name = tasks[i].subTaskName ? tasks[i].subTaskName : '';
      currentTask.style = tasks[i].style ? tasks[i].style : "normal";
      currentTask.color = tasks[i].color ? tasks[i].color : colors(currentTask.group);
      currentTask.order = tasks[i].order ? parseInt(tasks[i].order, 10) : 0;
      currentTask.from = dateFormat.parse(tasks[i].from);
      currentTask.to = dateFormat.parse(tasks[i].to);
      currentTask.to.setHours(currentTask.to.getHours() + 24); // Set the end of the day
      if (tasks[i].people) {
        if (Array.isArray(tasks[i].people)) {
          for (var j = 0; j < tasks[i].people.length; j++) {
            person = getPersonById(tasks[i].people[j], people);
            currentInstance.people.push({
              type: "people",
              order: person.order ? parseInt(person.order) : 0,
              group: person.name,
              from: currentTask.from,
              to: currentTask.to,
              name: currentTask.name !== '' ? currentTask.group + " — " + currentTask.name : currentTask.group,
              taskGroup: currentTask.group,
              taskOrder: currentTask.order,
              color: tasks[i].color ? tasks[i].color : colors(currentTask.group),
              involvement: tasks[i].involvement ? parseInt(tasks[i].involvement, 10) : 100
            });
          }
        } else {
          person = getPersonById(tasks[i].people, people);
          currentInstance.people.push({
            type: "people",
            order: person.order ? parseInt(person.order) : 0,
            group: person.name,
            from: currentTask.from,
            to: currentTask.to,
            name: currentTask.name !== '' ? currentTask.group + " — " + currentTask.name : currentTask.group,
            taskGroup: currentTask.group,
            taskOrder: currentTask.order,
            color: tasks[i].color ? tasks[i].color : colors(currentTask.group),
            involvement: tasks[i].involvement ? parseInt(tasks[i].involvement, 10) : 100
          });
        }
      }
      currentInstance.tasks.push(currentTask);
      currentTask = {};
    }
    refresh.apply(currentInstance);
  };

  var _parseFromOriginalFormat = function (currentInstance, colors, dateFormat) {
    var currentTask = {};

    var lines = (currentInstance.node.textContent || currentInstance.node.innerHTML || "").split("\n");
    for (var j = 0, line; line = lines[j], j < lines.length; j++) {
      var texts;
      line = line.replace(/^\s+|\s+$/g, "");

      // last line, empty
      if (line === "") {
        if (currentTask.name) {
          currentInstance.tasks.push(currentTask);
          currentTask = {};
        }
        continue;
      }

      // 1st line, project name followed by task name
      if (!currentTask.name && !currentTask.group) {
        texts = line.split(",");
        currentTask.type = "task";
        currentTask.group = texts[0].trim();
        currentTask.name = texts[1]?.trim();
        currentTask.url = texts[2]?.trim();
        currentTask.commit = texts[3]?.trim();
        if (currentInstance.tasks.length)
            currentInstance.tasks[currentInstance.tasks.length - 1].prev = currentTask;
        currentTask.style = currentTask.group.match(/^\*/) ? "bold" : "normal";
        currentTask.group = currentTask.group.replace(/^\*\s+/, "");
        currentTask.color = colors(currentTask.group);
        continue;
      }

      // 2nd line, dates from and to
      if (!currentTask.from && !currentTask.to) {
        texts = line.replace(/[^0-9\-\/]+/, " ").split(" ");
        currentTask.from = dateFormat.parse(texts[0]);
        currentTask.to = dateFormat.parse(texts[1]);
        currentTask.to.setHours(currentTask.to.getHours() + 24); // Set the end of the day
        continue;
      }

      // next lines, people
      {
        var matches, involvement;
        matches = line.match(/^\s*(\S*)\s*(?:\s+(\d+)%\s*)?(?:,\s*(\S*)\s*)?$/);

        involvement = matches[2] ? +matches[2] : 100;

        currentInstance.people.push({
          type: "people",
          group: matches[1],
          from: currentTask.from,
          to: currentTask.to,
          name: currentTask.name !== '' ? currentTask.name : currentTask.group,
          url: matches[3],
          taskGroup: currentTask.group,
          task: currentTask,
          color: colors(currentTask.group),
          involvement: involvement
        });
      }
    }
    refresh.apply(currentInstance);
  };

  var draw = function(items, options) {
    var currentInstance = this;

    // Drawing
    var barHeight = 20;
    var gap = barHeight + 4;
    var topPadding = 20 + (options.topPadding || 0);

    // Init width and height
    var h = items.length * gap + 40;
    var w = this.node.clientWidth;

    // Init d3
    var svg = options.svg || d3.select(this.node).append("svg").attr("width", w).attr("style", "overflow: visible");

    svg.attr("height", function() {
      return parseInt(svg.attr("height") || 0, 10) + h;
    });

    // Sort items
    items.sort(function(a, b) {
      if (a.group === b.group) {
        if (a.taskOrder !== b.taskOrder) {
          return a.taskOrder > b.taskOrder ? 1 : -1;
        }
        return a.from > b.from ? 1 : -1;
      } else {
        if (a.order !== b.order) {
          return a.order > b.order ? 1 : -1;
        }
        return a.group > b.group ? 1 : -1;
      }
    });

    // Filter groups
    var groups = [];
    var total = 0;
    for (var i = 0; i < items.length; i++){
      var j = 0;
      var found = false;
      while (j < groups.length && !found) {
        found = (groups[j].name === items[i].group);
        j++;
      }
      if (!found) {
        var count = 0;
        j = 0;
        while (j < items.length) {
          if (items[j].group === items[i].group) {
            count++;
          }
          j++;
        }
        groups.push({
          type: items[i].type,
          name: items[i].group,
          count: count,
          previous: total,
          style: items[i].style
        });
        total += count;
      }
    }

    // Patterns
    var patterns = 0;

    for (i = 0; i < items.length; i++) {
      if (items[i].type === "people" && items[i].involvement !== 100) {
        svg.append("defs")
          .append("pattern")
            .attr({ id: "pattern" + patterns, width:"8", height:"8", patternUnits:"userSpaceOnUse", patternTransform:"rotate(45)"})
          .append("rect")
            .attr({ width: Math.ceil(items[i].involvement * 8 / 100), height:"8",
              transform:"translate(0,0)", fill: items[i].color, "fill-opacity": 0.8});
        items[i].pattern = "url(#pattern" + patterns + ")";
        patterns++;
      }
    }

    // Draw vertical group boxes
    svg.append("g")
      .selectAll("rect")
      .data(groups)
      .enter()
      .append("rect")
      .attr("rx", 3)
      .attr("ry", 3)
      .attr("x", 0)
      .attr("y", function(d){
        return d.previous * gap + topPadding;
      })
      .attr("width", function(){
        return w;
      })
      .attr("height", function(d) {
        return d.count * gap - 4;
      })
      .attr("stroke", "none")
      .attr("fill", "#999")
      .attr("fill-opacity", 0.1);


    const html_re = /(\.html)$/;
    function showState(baseid, commit, url, description, look, person) {
      var original = document.getElementById(baseid);
      if (original) {
        if (url)
          original.src = url;
        else
          original.removeAttribute('src')
        const link = document.getElementById(`${baseid}-url`);
        if (link) {
          if (url) {
            link.href = url;
          } else {
            link.removeAttribute('href');
          }
          link.innerText = description;
        }
        const commitspan = document.getElementById(`${baseid}-commit`);
        if (commitspan) commitspan.innerText = `${commit.substring(0,7)}`;
        const what = document.getElementById(`${baseid}-what`);
        if (what) what.innerText = person;
        const lookspan = document.getElementById(`${baseid}-look`);
        if (lookspan) lookspan.innerText = look;
      }
    }
            // Draw vertical labels
    var axisText = svg.append("g")
      .selectAll("text")
      .data(groups)
      .enter()
      .append("text")
      .text(function(d){
        return d.name;
      })
      .attr("x", 10)
      .attr("y", function(d){
        return d.count * gap / 2 + d.previous * gap + topPadding + 2;
      })
      .attr("font-size", 11)
      .attr("font-weight", function(d) {
        return d.style;
      })
      .attr("text-anchor", "start")
      .attr("text-height", 14)
      .attr("fill", "#000")
      .on("mouseover", function(d) {
        if (d.type === "task" || (d.type === "people" && d.task.url)) {
          d3.select(this).style({cursor:"pointer"});
        }
      })
      .on("click",   function (d) {
        if (d.type === "task" && d.url) {
          if (currentInstance.graphOption.webFrames?.length == 2) {
            event.stopPropagation();
            if (currentInstance.graphOption.webFrames?.length == 2) {
              showState(currentInstance.graphOption.webFrames[0], d.commit,
                  `${d.url}/`);
              showState(currentInstance.graphOption.webFrames[1], SOURCE_COMMIT_SHA,
                  `index.${d.commit.substring(0,7)}.html`);
          } else
            window.location.href = d.url;
        } else if (d.type === "task") {
          refresh.apply(currentInstance, [d.name, this.getBBox().y]);
        }
      }
    });


    var sidePadding = options.sidePadding || axisText[0].parentNode.getBBox().width + 15;

    // Init time scale
    var timeScale = d3.time.scale()
      .clamp(true)
      .domain([
        d3.min(items, function(d) {
          return d.from;
        }),
        d3.max(items, function(d) {
          return d.to;
        })
      ]).range([0, w - sidePadding - 15]);

    // Init X Axis
    var xAxis = d3.svg.axis()
      .scale(timeScale)
      .orient("bottom")
      .ticks(d3.time.monday)
      .tickSize(- svg.attr("height") + topPadding + 20, 0, 0)
      .tickFormat(d3.time.format(currentInstance.graphOption.dateFormat ? currentInstance.graphOption.dateFormat : "%b %d"));
    if (currentInstance.graphOption.ticksType === "month") {
      xAxis.ticks(d3.time.month);
    }

    // Draw vertical grid
    var xAxisGroup = svg.append("g")
      .attr("transform", "translate(" + sidePadding + ", " + (svg.attr("height") - 20) + ")")
      .call(xAxis);

    xAxisGroup.selectAll("text")
      .style("text-anchor", "middle")
      .attr("fill", "#000")
      .attr("stroke", "none")
      .attr("font-size", 10)
      .attr("dy", "1em");

    xAxisGroup.selectAll(".tick line")
      .attr("stroke", "#dddddd")
      .attr("shape-rendering", "crispEdges");

    // add "top" X Axis
    if (currentInstance.graphOption.additionalXAxis) {
      var additionalXAxis = d3.svg.axis()
        .scale(timeScale)
        .orient("top")
        .ticks(d3.time.monday)
        .tickSize(- svg.attr("height") + topPadding + 20, 0, 0)
        .tickFormat(d3.time.format(currentInstance.graphOption.dateFormat ? currentInstance.graphOption.dateFormat : "%b %d"));
      if (currentInstance.graphOption.ticksType === "month") {
        additionalXAxis.ticks(d3.time.month);
      }
      var additionalXAxisGroup =  svg.append("g")
        .attr("transform", "translate(" + sidePadding + ", " + (svg.attr("height") - h) + ")")
        .call(additionalXAxis);
      additionalXAxisGroup.selectAll("text")
        .style("text-anchor", "middle")
        .attr("fill", "#000")
        .attr("stroke", "none")
        .attr("font-size", 10)
        .attr("dy", "1em");
      additionalXAxisGroup.selectAll(".tick line")
        .attr("stroke", "#dddddd")
        .attr("shape-rendering", "crispEdges");
    }

    // Now
    var now = new Date();
    if (now > timeScale.domain()[0] && now < timeScale.domain()[1]) {
      xAxisGroup
        .append("line")
        .attr("x1", timeScale(now))
        .attr("y1", 0)
        .attr("x2", timeScale(now))
        .attr("y2", -svg.attr("height") + topPadding + 20)
        .attr("class", "now");

      xAxisGroup.selectAll(".now")
        .attr("stroke", "red")
        .attr("opacity", 0.5)
        .attr("stroke-dasharray", "2,2")
        .attr("shape-rendering", "crispEdges");
    }

    // Items group
    var rectangles = svg.append("g")
      .attr("transform", "translate(" + sidePadding + ", 0)")
      .selectAll("rect")
      .data(items)
      .enter();

    // Draw items boxes
    rectangles.append("rect")
      .attr("rx", 3)
      .attr("ry", 3)
      .attr("x", function(d){
        return timeScale(d.from);
      })
      .attr("y", function(d, i){
        return i * gap + topPadding;
      })
      .attr("width", function(d){
        return timeScale(d.to) - timeScale(d.from);
      })
      .attr("height", barHeight)
      .attr("stroke", "none")
      .attr("fill", function(d) {
        return d.pattern || d.color;
      })
      .attr("fill-opacity", 0.5)
      .on("mouseover", function(d) {
        if (d.url || d.task?.url) {
          d3.select(this).style({cursor:"pointer"});
        }
      })
      .on("click",   function (d) {
          // window.location.href =d.url;
          event.stopPropagation();
          if (d.url) {
            /* click on the task under a project */
            if (currentInstance.graphOption.webFrames?.length == 2) {
              if (!d.prev)
                showState(currentInstance.graphOption.webFrames[0], "",
                  null,
                "Previously", "did not exist", "the entry point /");
              else
                showState(currentInstance.graphOption.webFrames[0], d.commit,
                    `index.${d.prev.commit.substring(0,7)}.html`,
                  "Previously", "looked", "the entry point /");

              showState(currentInstance.graphOption.webFrames[1], SOURCE_COMMIT_SHA,
                  '.',
                "Now", "looks", "the entry point /");
              }
          } else
          if (d.task.url) {
            /* click on file/person rectangle */
            if (currentInstance.graphOption.webFrames?.length == 2) {
              if (d.task.commit == SOURCE_COMMIT_SHA) {
                showState(currentInstance.graphOption.webFrames[0], d.task.prev.commit,
                  d.group.replace(html_re, `.${d.task.prev.commit.substring(0,7)}$1`),
                  "The previous version", "will now look", d.group);
              } else {
                showState(currentInstance.graphOption.webFrames[0], d.task.commit,
                    `${d.task.url}/${d.group}`,
                  "When published", "looked", d.group);
              }
              showState(currentInstance.graphOption.webFrames[1], SOURCE_COMMIT_SHA,
                  (d.task.commit == SOURCE_COMMIT_SHA) ?
                    `${d.group}` :
                    d.group.replace(html_re, `.${d.task.commit.substring(0,7)}$1`),
                  "Now", "looks", "it");
            } else 
              window.open(d.url, '_blank');
          }
      });

    // Draw items texts
    rectangles.append("text")
      .text(function(d){
        return d.name;
      })
      .attr("x", function(d){
        return timeScale(d.from) + (timeScale(d.to) - timeScale(d.from)) / 2;
      })
      .attr("y", function(d, i){
        return i * gap + 14 + topPadding;
      })
      .attr("font-size", 11)
      .attr("font-weight", function(d) {
        return d.style;
      })
      .attr("text-anchor", "middle")
      .attr("text-height", barHeight)
      .attr("fill", "#000")
      .style("pointer-events", "none");

    // Draw vertical mouse helper
    var verticalMouse = svg.append("line")
      .attr("x1", 0)
      .attr("y1", 0)
      .attr("x2", 0)
      .attr("y2", 0)
      .style("stroke", "black")
      .style("stroke-width", "1px")
      .style("stroke-dasharray", "2,2")
      .style("shape-rendering", "crispEdges")
      .style("pointer-events", "none")
      .style("display", "none");

    var verticalMouseBox = svg.append("rect")
      .attr("rx", 3)
      .attr("ry", 3)
      .attr("width", 50)
      .attr("height", barHeight)
      .attr("stroke", "none")
      .attr("fill", "black")
      .attr("fill-opacity", 0.8)
      .style("display", "none");

    var verticalMouseText = svg.append("text")
      .attr("font-size", 11)
      .attr("font-weight", "bold")
      .attr("text-anchor", "middle")
      .attr("text-height", barHeight)
      .attr("fill", "white")
      .style("display", "none");

    var verticalMouseTopPadding = 40;

    svg.on("mousemove", function () {
      var xCoord = d3.mouse(this)[0],
        yCoord = d3.mouse(this)[1];

      if (xCoord > sidePadding) {
        verticalMouse
          .attr("x1", xCoord)
          .attr("y1", 10)
          .attr("x2", xCoord)
          .attr("y2", svg.attr("height") - 20)
          .style("display", "block");

        verticalMouseBox
          .attr("x", xCoord - 25)
          .attr("y", yCoord - (barHeight + 8) / 2 + verticalMouseTopPadding)
          .style("display", "block");

        verticalMouseText
          .attr("transform", "translate(" + xCoord + "," + (yCoord + verticalMouseTopPadding) + ")")
          .text(d3.time.format(currentInstance.graphOption.dateFormat ? currentInstance.graphOption.dateFormat : "%b %d")(timeScale.invert(xCoord - sidePadding)))
          .style("display", "block");
      } else {
        verticalMouse.style("display", "none");
        verticalMouseBox.style("display", "none");
        verticalMouseText.style("display", "none");
      }
    });

    svg.on("mouseleave", function() {
      verticalMouse.style("display", "none");
      verticalMouseBox.style("display", "none");
      verticalMouseText.style("display", "none");
    });

    // options for the 2nd drawing
    return {
      sidePadding: sidePadding,
      topPadding: h,
      svg: svg
    };
  };

  document.addEventListener("DOMContentLoaded", function(){
    if(typeof window.__isRoadmapLoaded === "undefined") {
      parse();
      window.__isRoadmapLoaded = parse;
    }
  });

})();