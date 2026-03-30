(() => {
  function createRiskdashStateEngine() {
    const chartState = new Map();
    let protocolPairs = [];

    function getProtocolPairs() {
      return protocolPairs;
    }

    function setProtocolPairs(next) {
      protocolPairs = Array.isArray(next) ? next : [];
      return protocolPairs;
    }

    return {
      chartState,
      getProtocolPairs,
      setProtocolPairs,
    };
  }

  window.__createRiskdashStateEngine = createRiskdashStateEngine;
})();
