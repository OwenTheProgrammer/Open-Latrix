// -- Open Latrix by OwenTheProgrammer --
Shader "OwenTheProgrammer/OpenLatrix/OpenStencil" {
    Properties {
        [IntRange] _StencilRef("Stencil Reference", Range(0, 255)) = 140
    }
    SubShader {
        ZWrite Off
        ZTest Always
        Cull Front
        Tags {"ForceNoShadowCasting"="True"}
        Pass {
            Stencil {
                Ref [_StencilRef]
                Comp Always
                Pass Replace
                Fail Keep
            }
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            float4 vert(float4 vertex : POSITION) : SV_POSITION {
                return UnityObjectToClipPos(vertex);
            }

            void frag(float4 vertex : SV_POSITION) {}
            ENDCG
        }
    }
}